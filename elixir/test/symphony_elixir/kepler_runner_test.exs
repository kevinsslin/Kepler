defmodule SymphonyElixir.KeplerRunnerTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Execution.Runner
  alias SymphonyElixir.Kepler.Run

  defmodule FakeGitHubClient do
    @spec workspace_env(map()) :: {:ok, map()}
    def workspace_env(_repo), do: {:ok, %{}}

    @spec installation_auth(map()) :: {:ok, map()}
    def installation_auth(_repo), do: {:ok, %{installation_id: 99, token: "github-token"}}

    @spec find_open_pull_request(map(), String.t()) :: {:ok, map() | nil}
    def find_open_pull_request(_repo, branch) do
      notify({:find_open_pull_request, branch})
      {:ok, :persistent_term.get({__MODULE__, :open_pull_request}, nil)}
    end

    @spec create_pull_request(map(), String.t(), String.t(), String.t()) :: {:ok, String.t()}
    def create_pull_request(_repo, branch, title, body) do
      notify({:create_pull_request, branch, title, body})
      {:ok, "https://github.com/example/repo-api/pull/1"}
    end

    @spec update_pull_request(map(), integer(), String.t() | nil, String.t()) :: {:ok, String.t()}
    def update_pull_request(_repo, number, title, body) do
      notify({:update_pull_request, number, title, body})
      {:ok, "https://github.com/example/repo-api/pull/#{number}"}
    end

    defp notify(message) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, message)
      end
    end
  end

  defmodule FakeLinearClient do
    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()}
    def graphql(_query, _variables, _opts \\ []), do: {:ok, %{}}
  end

  defmodule FakeAppServer do
    @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()}
    def run(workspace_path, prompt, issue, _opts \\ []) do
      current_branch = current_branch(workspace_path)
      notify({:app_server_started_on_branch, current_branch, issue.branch_name})
      notify({:app_server_prompt, prompt})

      case :persistent_term.get({__MODULE__, :scenario}, :push_commit) do
        :push_commit ->
          commit_change(workspace_path, issue.branch_name, push?: true)

        :push_commit_with_reference_context ->
          assert_reference_repo_present!(workspace_path)
          commit_change(workspace_path, issue.branch_name, push?: true)

        :commit_without_push ->
          commit_change(workspace_path, issue.branch_name, push?: false)

        :switch_back_to_main ->
          commit_change(workspace_path, issue.branch_name, push?: false)
          git!(workspace_path, ["checkout", "main"])

        :no_change ->
          :ok
      end

      {:ok, %{result: :turn_completed}}
    end

    defp commit_change(workspace_path, branch, opts) do
      change_path = Path.join(workspace_path, "lib-change.txt")
      report_path = Path.join(workspace_path, ".kepler/pr-report.json")
      workpad_path = Path.join(workspace_path, ".kepler/workpad.md")
      File.mkdir_p!(Path.dirname(report_path))
      File.write!(change_path, "updated at #{System.unique_integer([:positive])}\n")
      File.write!(workpad_path, "local notes that should stay untracked\n")

      File.write!(
        report_path,
        Jason.encode!(%{
          "change_type" => "backend",
          "summary" => ["Updated hosted runner test fixture"],
          "validation" => [
            %{"command" => "mix test test/symphony_elixir/kepler_runner_test.exs", "kind" => "test", "result" => "passed"}
          ],
          "blockers" => []
        })
      )

      git!(workspace_path, ["add", "lib-change.txt"])
      git!(workspace_path, ["commit", "-m", "Apply #{branch} fixture change"])

      if Keyword.get(opts, :push?, false) do
        git!(workspace_path, ["push", "-u", "origin", branch])
      end
    end

    defp assert_reference_repo_present!(workspace_path) do
      reference_readme = Path.join(workspace_path, ".kepler/refs/repo-web/README.md")

      case File.read(reference_readme) do
        {:ok, content} ->
          if content =~ "Reference repo" do
            :ok
          else
            raise "expected reference repo README, got: #{inspect(content)}"
          end

        {:error, reason} ->
          raise "failed to read reference repo README: #{inspect(reason)}"
      end
    end

    defp current_branch(workspace_path) do
      case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} -> String.trim(output)
        _ -> nil
      end
    end

    defp git!(workspace_path, args) do
      case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true, env: git_identity_env()) do
        {_output, 0} -> :ok
        {output, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{output}"
      end
    end

    defp git_identity_env do
      [
        {"GIT_AUTHOR_NAME", "Kepler Runner Test"},
        {"GIT_AUTHOR_EMAIL", "kepler-runner@example.com"},
        {"GIT_COMMITTER_NAME", "Kepler Runner Test"},
        {"GIT_COMMITTER_EMAIL", "kepler-runner@example.com"}
      ]
    end

    defp notify(message) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, message)
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "kepler-runner-test-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "kepler.yml")
    remote_api_path = Path.join(root, "remote-api.git")
    source_api_path = Path.join(root, "source-api")
    remote_web_path = Path.join(root, "remote-web.git")
    source_web_path = Path.join(root, "source-web")

    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_github_token = System.get_env("GITHUB_TOKEN")
    original_github_recipient = :persistent_term.get({FakeGitHubClient, :recipient}, :__missing__)
    original_open_pull_request = :persistent_term.get({FakeGitHubClient, :open_pull_request}, :__missing__)
    original_app_server_recipient = :persistent_term.get({FakeAppServer, :recipient}, :__missing__)
    original_app_server_scenario = :persistent_term.get({FakeAppServer, :scenario}, :__missing__)

    File.mkdir_p!(root)
    init_remote_repo!(source_api_path, remote_api_path, readme: "# Primary repo\n")
    init_remote_repo!(source_web_path, remote_web_path, readme: "# Reference repo\n")
    write_kepler_config!(config_path, root, remote_api_path, remote_web_path)

    Config.set_config_file_path(config_path)
    System.put_env("GITHUB_TOKEN", "runner-test-token")
    :persistent_term.put({FakeGitHubClient, :recipient}, self())
    :persistent_term.put({FakeAppServer, :recipient}, self())

    on_exit(fn ->
      if is_nil(original_config_path),
        do: Config.clear_config_file_path(),
        else: Config.set_config_file_path(original_config_path)

      restore_env("GITHUB_TOKEN", original_github_token)
      restore_persistent_term({FakeGitHubClient, :recipient}, original_github_recipient)
      restore_persistent_term({FakeGitHubClient, :open_pull_request}, original_open_pull_request)
      restore_persistent_term({FakeAppServer, :recipient}, original_app_server_recipient)
      restore_persistent_term({FakeAppServer, :scenario}, original_app_server_scenario)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "runner creates and verifies the canonical issue branch before publishing a PR" do
    :persistent_term.put({FakeAppServer, :scenario}, :push_commit)

    assert {:ok, result} =
             Runner.run(run("APP-42", "Implement hosted validation"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    assert_receive {:app_server_started_on_branch, "kepler/APP-42", "kepler/APP-42"}
    assert_receive {:find_open_pull_request, "kepler/APP-42"}
    assert_receive {:create_pull_request, "kepler/APP-42", "APP-42: Implement hosted validation", body}
    assert body =~ "https://linear.app/example-workspace/issue/APP-42"
    assert body =~ "## Summary"
    assert body =~ "mix test test/symphony_elixir/kepler_runner_test.exs"
    assert result.branch == "kepler/APP-42"
    assert result.pr_url == "https://github.com/example/repo-api/pull/1"
  end

  test "runner syncs configured reference repositories as read-only context and ignores local operational files" do
    :persistent_term.put({FakeAppServer, :scenario}, :push_commit_with_reference_context)

    assert {:ok, result} =
             Runner.run(run("APP-44", "Inspect upstream context"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    assert_receive {:app_server_started_on_branch, "kepler/APP-44", "kepler/APP-44"}
    assert_receive {:app_server_prompt, prompt}
    assert prompt =~ ".kepler/refs/repo-web"
    assert_receive {:find_open_pull_request, "kepler/APP-44"}
    assert result.pr_url == "https://github.com/example/repo-api/pull/1"
  end

  test "runner ignores a persisted default branch and recreates the canonical issue branch" do
    :persistent_term.put({FakeAppServer, :scenario}, :push_commit)

    assert {:ok, result} =
             Runner.run(
               run("APP-43", "Recover canonical branch", branch: "main"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    assert_receive {:app_server_started_on_branch, "kepler/APP-43", "kepler/APP-43"}
    assert_receive {:find_open_pull_request, "kepler/APP-43"}
    assert result.branch == "kepler/APP-43"
  end

  test "runner fails when the branch was committed locally but never pushed" do
    :persistent_term.put({FakeAppServer, :scenario}, :commit_without_push)

    assert {:error, {:issue_branch_not_pushed, "kepler/APP-88"}} =
             Runner.run(run("APP-88", "Keep branch local"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    refute_receive {:create_pull_request, _, _, _}
  end

  test "runner updates an existing pull request instead of creating a second one" do
    :persistent_term.put({FakeAppServer, :scenario}, :push_commit)
    :persistent_term.put({FakeGitHubClient, :open_pull_request}, %{number: 7})

    assert {:ok, result} =
             Runner.run(run("APP-55", "Refresh hosted validation"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    assert_receive {:find_open_pull_request, "kepler/APP-55"}
    assert_receive {:update_pull_request, 7, nil, body}
    assert body =~ "https://linear.app/example-workspace/issue/APP-55"
    refute_receive {:create_pull_request, _, _, _}
    assert result.pr_url == "https://github.com/example/repo-api/pull/7"
  end

  test "runner skips PR publication when the issue branch has no delta from the default branch" do
    :persistent_term.put({FakeAppServer, :scenario}, :no_change)

    assert {:ok, result} =
             Runner.run(run("APP-56", "No-op hosted validation"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    assert_receive {:app_server_started_on_branch, "kepler/APP-56", "kepler/APP-56"}
    refute_receive {:find_open_pull_request, "kepler/APP-56"}
    refute_receive {:create_pull_request, _, _, _}
    refute_receive {:update_pull_request, _, _, _}
    assert result.branch == "kepler/APP-56"
    assert result.pr_url == nil
  end

  test "runner fails when Codex leaves the expected issue branch" do
    :persistent_term.put({FakeAppServer, :scenario}, :switch_back_to_main)

    assert {:error, {:unexpected_execution_branch, "main", "kepler/APP-99"}} =
             Runner.run(run("APP-99", "Switch back to main"),
               github_client: FakeGitHubClient,
               linear_client: FakeLinearClient,
               app_server_module: FakeAppServer
             )

    refute_receive {:create_pull_request, _, _, _}
  end

  defp run(identifier, title, attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    Run.new(%{
      linear_issue_id: "issue-#{identifier}",
      linear_issue_identifier: identifier,
      linear_issue_title: title,
      linear_issue_url: "https://linear.app/example-workspace/issue/#{identifier}",
      linear_agent_session_id: "session-#{identifier}",
      repository_id: "repo-api",
      branch: Map.get(attrs, :branch)
    })
  end

  defp init_remote_repo!(source_path, remote_path, opts) do
    File.mkdir_p!(source_path)
    git!(source_path, ["init", "-b", "main"])
    git!(source_path, ["config", "user.name", "Kepler Runner Test"])
    git!(source_path, ["config", "user.email", "kepler-runner@example.com"])
    File.write!(Path.join(source_path, "README.md"), Keyword.get(opts, :readme, "# Runner test\n"))
    git!(source_path, ["add", "README.md"])
    git!(source_path, ["commit", "-m", "Initial commit"])

    git!(Path.dirname(remote_path), ["init", "--bare", remote_path])
    git!(source_path, ["remote", "add", "origin", remote_path])
    git!(source_path, ["push", "-u", "origin", "main"])
  end

  defp write_kepler_config!(config_path, root, remote_api_path, remote_web_path) do
    File.write!(
      config_path,
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
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "#{remote_api_path}"
          default_branch: "main"
          workflow_path: "WORKFLOW.md"
          labels: ["api"]
          reference_repository_ids: ["repo-web"]
        - id: "repo-web"
          full_name: "example/repo-web"
          clone_url: "#{remote_web_path}"
          default_branch: "main"
          workflow_path: "WORKFLOW.md"
          labels: ["web"]
      """
    )
  end

  defp git!(workspace_path, args) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true, env: git_identity_env()) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed with #{status}: #{output}"
    end
  end

  defp git_identity_env do
    [
      {"GIT_AUTHOR_NAME", "Kepler Runner Test"},
      {"GIT_AUTHOR_EMAIL", "kepler-runner@example.com"},
      {"GIT_COMMITTER_NAME", "Kepler Runner Test"},
      {"GIT_COMMITTER_EMAIL", "kepler-runner@example.com"}
    ]
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_persistent_term(key, :__missing__), do: :persistent_term.erase(key)
  defp restore_persistent_term(key, value), do: :persistent_term.put(key, value)
end
