defmodule SymphonyElixir.Kepler.WorkflowResolverTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Config.Schema
  alias SymphonyElixir.Kepler.Config.Schema.Repository
  alias SymphonyElixir.Kepler.WorkflowResolver
  alias SymphonyElixir.Workflow

  setup do
    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_github_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    root =
      Path.join(
        System.tmp_dir!(),
        "kepler-workflow-resolver-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      if is_nil(original_config_path),
        do: Config.clear_config_file_path(),
        else: Config.set_config_file_path(original_config_path)

      restore_env("GITHUB_TOKEN", original_github_token)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "repo-local WORKFLOW.md wins over configured fallback and settings are normalized", %{root: root} do
    workspace = Path.join(root, "workspace")
    fallback_path = Path.join(root, "fallback.md")
    repo_workflow_path = Path.join(workspace, "WORKFLOW.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(workspace)
    File.write!(fallback_path, workflow_body("Fallback prompt"))
    File.write!(repo_workflow_path, workflow_body("Repo-local prompt"))
    File.write!(config_path, kepler_config(fallback_path, root))
    Config.set_config_file_path(config_path)

    assert {:ok, resolved} = WorkflowResolver.load(workspace, repository())

    assert resolved.workflow_path == repo_workflow_path
    assert resolved.workflow.prompt =~ "Repo-local prompt"
    refute resolved.workflow.prompt =~ "Fallback prompt"
    assert resolved.workflow.prompt =~ "All outward-facing artifacts for this run must be written in English"
    assert resolved.workflow.prompt =~ "Do not paste raw local filesystem paths for screenshot evidence"
    assert resolved.settings.workspace.root == Config.settings!().workspace.root
    assert resolved.settings.worker.ssh_hosts == []
    assert resolved.settings.codex.thread_sandbox == "danger-full-access"
    assert resolved.settings.codex.turn_sandbox_policy == %{"type" => "dangerFullAccess"}
  end

  test "configured fallback is used when repo-local workflow is missing", %{root: root} do
    workspace = Path.join(root, "workspace")
    fallback_path = Path.join(root, "fallback.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(workspace)
    File.write!(fallback_path, workflow_body("Fallback only prompt"))
    File.write!(config_path, kepler_config(fallback_path, root))
    Config.set_config_file_path(config_path)

    assert {:ok, resolved} = WorkflowResolver.load(workspace, repository())

    assert resolved.workflow_path == fallback_path
    assert resolved.workflow.prompt =~ "Fallback only prompt"
    assert resolved.workflow.prompt =~ "All outward-facing artifacts for this run must be written in English"
  end

  test "custom repository workflow path overrides fallback when present", %{root: root} do
    workspace = Path.join(root, "workspace")
    custom_dir = Path.join(workspace, ".kepler")
    custom_workflow_path = Path.join(custom_dir, "WORKFLOW.md")
    fallback_path = Path.join(root, "fallback.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(custom_dir)
    File.write!(custom_workflow_path, workflow_body("Custom workflow prompt"))
    File.write!(fallback_path, workflow_body("Fallback prompt"))
    File.write!(config_path, kepler_config(fallback_path, root))
    Config.set_config_file_path(config_path)

    assert {:ok, resolved} =
             WorkflowResolver.load(workspace, repository(workflow_path: ".kepler/WORKFLOW.md"))

    assert resolved.workflow_path == custom_workflow_path
    assert resolved.workflow.prompt =~ "Custom workflow prompt"
    refute resolved.workflow.prompt =~ "Fallback prompt"
  end

  test "missing custom repository workflow path falls back to configured fallback", %{root: root} do
    workspace = Path.join(root, "workspace")
    fallback_path = Path.join(root, "fallback.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(workspace)
    File.write!(fallback_path, workflow_body("Fallback prompt"))
    File.write!(config_path, kepler_config(fallback_path, root))
    Config.set_config_file_path(config_path)

    assert {:ok, resolved} =
             WorkflowResolver.load(workspace, repository(workflow_path: ".kepler/WORKFLOW.md"))

    assert resolved.workflow_path == fallback_path
    assert resolved.workflow.prompt =~ "Fallback prompt"
  end

  test "missing repo-local workflow and unreadable fallback returns a fallback load error", %{root: root} do
    workspace = Path.join(root, "workspace")
    fallback_path = Path.join(root, "missing-fallback.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(workspace)
    File.write!(config_path, kepler_config(fallback_path, root))
    Config.set_config_file_path(config_path)

    assert {:error, {:missing_workflow_file, ^fallback_path, :enoent}} =
             WorkflowResolver.load(workspace, repository())
  end

  test "bundled fallback workflow parses and includes hosted execution guardrails" do
    bundled_path = Schema.default_fallback_workflow_path()

    assert {:ok, workflow} = Workflow.load(bundled_path)

    assert workflow.prompt =~ ".kepler/workpad.md"
    assert workflow.prompt =~ ".kepler/pr-report.json"
    assert workflow.prompt =~ ".kepler/refs/"
    assert workflow.prompt =~ "kepler/{{ issue.identifier }}"
    assert workflow.prompt =~ "origin/<issue-branch>"
    assert workflow.prompt =~ "\"change_type\": \"frontend\""
    assert workflow.prompt =~ "\"validation\""
    assert workflow.prompt =~ "screenshot evidence is mandatory"
    assert workflow.prompt =~ "passing automated tests are mandatory"
    assert workflow.prompt =~ "commit the work and push the issue branch before finishing"
    assert workflow.prompt =~ "Do not create duplicate PRs"
    assert workflow.prompt =~ "All outward-facing artifacts for this run must be written in English"
    assert workflow.prompt =~ "Do not paste raw local filesystem paths for screenshot evidence"
  end

  test "hosted codex sandbox overrides repo-local workflow sandbox settings", %{root: root} do
    workspace = Path.join(root, "workspace")
    repo_workflow_path = Path.join(workspace, "WORKFLOW.md")
    config_path = Path.join(root, "kepler.yml")

    File.mkdir_p!(workspace)
    File.write!(repo_workflow_path, workflow_body("Repo-local prompt", sandbox: :workspace_write))
    File.write!(config_path, kepler_config(nil, root))
    Config.set_config_file_path(config_path)

    assert {:ok, resolved} = WorkflowResolver.load(workspace, repository())

    assert resolved.workflow_path == repo_workflow_path
    assert resolved.settings.codex.thread_sandbox == "danger-full-access"
    assert resolved.settings.codex.turn_sandbox_policy == %{"type" => "dangerFullAccess"}
  end

  defp repository(opts \\ []) do
    %Repository{
      id: "repo-api",
      full_name: "example/repo-api",
      clone_url: "https://github.com/example/repo-api.git",
      default_branch: "main",
      workflow_path: Keyword.get(opts, :workflow_path, "WORKFLOW.md"),
      provider: "codex",
      labels: [],
      team_keys: [],
      project_ids: [],
      project_slugs: [],
      reference_repository_ids: []
    }
  end

  defp kepler_config(fallback_path, root) do
    routing_block =
      case fallback_path do
        nil ->
          ""

        path ->
          """
          routing:
            fallback_workflow_path: "#{path}"
            ambiguous_choice_limit: 3
          """
      end

    """
    service_name: "Kepler"
    linear:
      api_key: "linear-token"
      webhook_secret: "linear-secret"
    github:
      bot_name: "Kepler Bot"
      bot_email: "kepler@example.com"
    workspace:
      root: "#{Path.join(root, "workspaces")}"
    state:
      root: "#{Path.join(root, "state")}"
      file_name: "runs.json"
    #{routing_block}
    repositories:
      - id: "repo-api"
        full_name: "example/repo-api"
        clone_url: "https://github.com/example/repo-api.git"
        default_branch: "main"
        workflow_path: "WORKFLOW.md"
        provider: "codex"
    """
  end

  defp workflow_body(prompt, opts \\ []) do
    sandbox_block =
      case Keyword.get(opts, :sandbox) do
        :workspace_write ->
          """
          codex:
            thread_sandbox: "workspace-write"
            turn_sandbox_policy:
              type: workspaceWrite
          """

        _ ->
          nil
      end

    [
      "---",
      "workspace:",
      "  root: \"/tmp/repo-local-root\"",
      "worker:",
      "  ssh_hosts:",
      "    - \"worker-a\"",
      sandbox_block,
      "---",
      prompt
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
