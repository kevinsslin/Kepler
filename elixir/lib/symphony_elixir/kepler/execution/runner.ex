defmodule SymphonyElixir.Kepler.Execution.Runner do
  @moduledoc """
  Executes a single Kepler run inside an isolated repository workspace.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Execution.PullRequestBody
  alias SymphonyElixir.Kepler.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Kepler.Run
  alias SymphonyElixir.Kepler.WorkflowResolver
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Workspace

  @type run_result :: %{
          branch: String.t() | nil,
          codex_result: map() | nil,
          github_installation_id: integer() | nil,
          pr_url: String.t() | nil,
          summary: String.t(),
          workspace_path: String.t()
        }

  @spec run(Run.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(%Run{} = run, opts \\ []) do
    repository = repository!(run.repository_id)
    github_client = Keyword.get(opts, :github_client, github_client())
    linear_client = Keyword.get(opts, :linear_client, linear_client())
    app_server_module = Keyword.get(opts, :app_server_module, app_server_module())
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    workspace_path = workspace_path(run, repository)
    expected_branch = expected_issue_branch(run, repository.default_branch)

    with {:ok, github_env} <- github_env(github_client, repository),
         {:ok, created?} <- ensure_repository_workspace(workspace_path, repository, github_env),
         :ok <- ensure_local_operational_paths_ignored(workspace_path),
         :ok <- ensure_reference_workspaces(workspace_path, repository, github_env),
         :ok <- ensure_issue_branch(workspace_path, expected_branch, repository.default_branch, github_env),
         {:ok, resolved_workflow} <- WorkflowResolver.load(workspace_path, repository) do
      do_run(%{
        workspace_path: workspace_path,
        run: run,
        repository: repository,
        created?: created?,
        expected_branch: expected_branch,
        resolved_workflow: resolved_workflow,
        github_env: github_env,
        github_client: github_client,
        linear_client: linear_client,
        app_server_module: app_server_module,
        on_event: on_event
      })
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_run(%{
         workspace_path: workspace_path,
         run: run,
         repository: repository,
         created?: created?,
         expected_branch: expected_branch,
         resolved_workflow: resolved_workflow,
         github_env: github_env,
         github_client: github_client,
         linear_client: linear_client,
         app_server_module: app_server_module,
         on_event: on_event
       }) do
    result =
      try do
        issue = issue_struct(run, expected_branch)
        prompt = prompt(run, resolved_workflow.workflow, issue, repository)

        with :ok <-
               maybe_run_after_create_hook(
                 created?,
                 workspace_path,
                 run,
                 resolved_workflow.settings,
                 github_env
               ),
             :ok <-
               Workspace.run_before_run_hook(
                 workspace_path,
                 run.linear_issue_identifier,
                 nil,
                 settings: resolved_workflow.settings,
                 env: github_env
               ) do
          run_codex(
            workspace_path,
            issue,
            prompt,
            resolved_workflow.settings,
            github_env,
            linear_client,
            app_server_module,
            on_event
          )
        end
      after
        Workspace.run_after_run_hook(
          workspace_path,
          run.linear_issue_identifier,
          nil,
          settings: resolved_workflow.settings,
          env: github_env
        )
      end

    case result do
      {:ok, app_result} ->
        branch = current_branch(workspace_path)

        with :ok <- ensure_expected_issue_branch(branch, expected_branch),
             :ok <- ensure_clean_workspace(workspace_path),
             {:ok, pr_url} <-
               maybe_publish_pull_request(
                 github_client,
                 repository,
                 run,
                 branch,
                 workspace_path,
                 github_env
               ) do
          {:ok,
           %{
             branch: branch,
             codex_result: app_result.result,
             github_installation_id: installation_id(github_client, repository),
             pr_url: pr_url,
             summary: summary_text(workspace_path, branch, pr_url, app_result.result),
             workspace_path: workspace_path
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_codex(workspace_path, issue, prompt, settings, github_env, linear_client, app_server_module, on_event) do
    app_server_module.run(
      workspace_path,
      prompt,
      issue,
      settings: settings,
      env: github_env,
      on_message: fn message ->
        _ = on_event.(message)
      end,
      tool_executor: fn tool, arguments ->
        DynamicTool.execute(
          tool,
          arguments,
          linear_client: fn query, variables, _opts ->
            linear_client.graphql(query, variables, [])
          end
        )
      end
    )
  end

  defp maybe_run_after_create_hook(false, _workspace_path, _run, _settings, _github_env), do: :ok

  defp maybe_run_after_create_hook(true, workspace_path, run, settings, github_env) do
    Workspace.run_after_create_hook(
      workspace_path,
      run.linear_issue_identifier,
      nil,
      settings: settings,
      env: github_env
    )
  end

  defp prompt(run, workflow, %Issue{} = issue, repository) do
    base_prompt =
      PromptBuilder.build_prompt(
        issue,
        workflow: workflow,
        extra_assigns: %{
          prompt_context: run.prompt_context,
          follow_up_prompts: active_follow_up_prompts(run)
        }
      )

    [
      base_prompt,
      format_prompt_context(run.prompt_context),
      format_follow_up_prompts(active_follow_up_prompts(run)),
      format_reference_repositories(repository)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp format_prompt_context(nil), do: nil

  defp format_prompt_context(prompt_context) when is_binary(prompt_context) do
    """
    Linear agent session context:

    #{prompt_context}
    """
  end

  defp format_follow_up_prompts([]), do: nil

  defp format_follow_up_prompts(prompts) when is_list(prompts) do
    formatted_prompts =
      prompts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", fn prompt -> "- #{prompt}" end)

    if formatted_prompts == "" do
      nil
    else
      """
      Follow-up prompts from the Linear session:

      #{formatted_prompts}
      """
    end
  end

  defp active_follow_up_prompts(run) do
    case run.active_follow_up_prompts do
      prompts when is_list(prompts) and prompts != [] -> prompts
      _ -> run.follow_up_prompts
    end
  end

  defp issue_struct(run, expected_branch) do
    %Issue{
      id: run.linear_issue_id,
      identifier: run.linear_issue_identifier,
      title: run.linear_issue_title,
      description: run.linear_issue_description,
      url: run.linear_issue_url,
      branch_name: expected_branch,
      labels: run.issue_labels
    }
  end

  defp format_reference_repositories(repository) do
    reference_paths =
      repository
      |> reference_repositories()
      |> Enum.map_join("\n", fn reference_repository ->
        "- `#{reference_repository.id}` at `.kepler/refs/#{reference_repository.id}`"
      end)

    if reference_paths == "" do
      nil
    else
      """
      Read-only reference repositories are available for context:

      #{reference_paths}

      Treat these directories as read-only context only. All code changes, commits, and PR updates must stay inside the primary repository workspace.
      """
    end
  end

  defp ensure_repository_workspace(workspace_path, repository, env) do
    if File.dir?(Path.join(workspace_path, ".git")) do
      with :ok <- git(workspace_path, ["remote", "set-url", "origin", clone_url(repository)], env),
           :ok <- git(workspace_path, ["fetch", "origin", repository.default_branch, "--prune"], env),
           :ok <- git(workspace_path, ["checkout", repository.default_branch], env),
           :ok <- git(workspace_path, ["reset", "--hard", "origin/#{repository.default_branch}"], env) do
        {:ok, false}
      end
    else
      parent = Path.dirname(workspace_path)
      File.rm_rf!(workspace_path)
      File.mkdir_p!(parent)
      File.mkdir_p!(workspace_path)

      with :ok <- git(workspace_path, ["clone", clone_url(repository), "."], env),
           :ok <- git(workspace_path, ["checkout", repository.default_branch], env) do
        {:ok, true}
      end
    end
  end

  defp ensure_reference_workspaces(workspace_path, repository, env) do
    references = reference_repositories(repository)

    case references do
      [] ->
        :ok

      _ ->
        sync_reference_repositories(workspace_path, references, env)
    end
  end

  defp sync_reference_repositories(workspace_path, references, env) do
    Enum.reduce_while(references, :ok, fn reference_repository, :ok ->
      case ensure_reference_workspace(workspace_path, reference_repository, env) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_reference_workspace(workspace_path, repository, env) do
    reference_path = reference_workspace_path(workspace_path, repository.id)

    with :ok <- set_reference_workspace_writable(reference_path),
         {:ok, _created?} <- sync_repository_workspace(reference_path, repository, env),
         :ok <- set_reference_workspace_read_only(reference_path) do
      :ok
    else
      {:error, reason} ->
        {:error, {:reference_repository_sync_failed, repository.id, reason}}
    end
  end

  defp sync_repository_workspace(workspace_path, repository, env) do
    if File.dir?(Path.join(workspace_path, ".git")) do
      with :ok <- git(workspace_path, ["remote", "set-url", "origin", clone_url(repository)], env),
           :ok <- git(workspace_path, ["fetch", "origin", repository.default_branch, "--prune"], env),
           :ok <- git(workspace_path, ["checkout", repository.default_branch], env),
           :ok <- git(workspace_path, ["reset", "--hard", "origin/#{repository.default_branch}"], env) do
        {:ok, false}
      end
    else
      parent = Path.dirname(workspace_path)
      File.rm_rf!(workspace_path)
      File.mkdir_p!(parent)
      File.mkdir_p!(workspace_path)

      with :ok <- git(workspace_path, ["clone", clone_url(repository), "."], env),
           :ok <- git(workspace_path, ["checkout", repository.default_branch], env) do
        {:ok, true}
      end
    end
  end

  defp ensure_local_operational_paths_ignored(workspace_path) do
    exclude_path = Path.join([workspace_path, ".git", "info", "exclude"])
    File.mkdir_p!(Path.dirname(exclude_path))

    patterns = [
      ".kepler/workpad.md",
      ".kepler/pr-report.json",
      ".kepler/pr_report.json",
      ".kepler/refs/"
    ]

    existing =
      case File.read(exclude_path) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
        {:error, reason} -> raise File.Error, reason: reason, action: "read", path: exclude_path
      end

    missing_patterns = Enum.reject(patterns, &String.contains?(existing, &1))

    case missing_patterns do
      [] ->
        :ok

      _ ->
        suffix = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
        additions = Enum.join(missing_patterns, "\n")
        File.write!(exclude_path, existing <> suffix <> additions <> "\n")
        :ok
    end
  end

  defp set_reference_workspace_writable(path) do
    chmod_recursive(path, "u+w")
  end

  defp set_reference_workspace_read_only(path) do
    chmod_recursive(path, "a-w")
  end

  defp chmod_recursive(path, mode) do
    if File.exists?(path) do
      case System.cmd("chmod", ["-R", mode, path], stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:chmod_failed, path, mode, status, output}}
      end
    else
      :ok
    end
  end

  defp git(workspace_path, args, env) do
    case System.cmd("git", args, cd: workspace_path, stderr_to_stdout: true, env: env) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:git_command_failed, args, status, output}}
    end
  end

  defp ensure_issue_branch(workspace_path, branch, default_branch, env)
       when is_binary(branch) and branch != "" do
    cond do
      local_branch_exists?(workspace_path, branch) ->
        git(workspace_path, ["checkout", branch], env)

      remote_branch_exists?(workspace_path, branch, env) ->
        with :ok <- git(workspace_path, ["fetch", "origin", branch, "--prune"], env) do
          git(workspace_path, ["checkout", "-B", branch, "origin/#{branch}"], env)
        end

      true ->
        git(workspace_path, ["checkout", "-B", branch, "origin/#{default_branch}"], env)
    end
  end

  defp ensure_expected_issue_branch(branch, expected_branch)
       when is_binary(branch) and branch == expected_branch,
       do: :ok

  defp ensure_expected_issue_branch(branch, expected_branch) do
    {:error, {:unexpected_execution_branch, branch, expected_branch}}
  end

  defp ensure_clean_workspace(workspace_path) do
    case System.cmd("git", ["status", "--porcelain"], cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :ok
          dirty -> {:error, {:dirty_workspace_after_execution, dirty}}
        end

      {output, status} ->
        {:error, {:git_command_failed, ["status", "--porcelain"], status, output}}
    end
  end

  defp local_branch_exists?(workspace_path, branch) do
    case System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp remote_branch_exists?(workspace_path, branch, env) do
    case System.cmd("git", ["ls-remote", "--exit-code", "--heads", "origin", branch],
           cd: workspace_path,
           stderr_to_stdout: true,
           env: env
         ) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp summary_text(workspace_path, branch, pr_url, codex_result) do
    branch_text =
      case branch do
        nil -> "No branch was detected."
        value -> "Current branch: `#{value}`."
      end

    pr_text =
      case pr_url do
        nil -> "No pull request URL was detected."
        value -> "Pull request: #{value}"
      end

    changed_files =
      case System.cmd("git", ["status", "--short"], cd: workspace_path, stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.trim()
          |> case do
            "" -> "Workspace is clean after execution."
            lines -> "Workspace status:\n\n```\n#{lines}\n```"
          end

        _ ->
          "Workspace status could not be collected."
      end

    final_message =
      case codex_result do
        %{final_agent_message: value} when is_binary(value) and value != "" ->
          "Final Codex response:\n\n#{value}"

        _ ->
          nil
      end

    [branch_text, pr_text, changed_files, final_message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp maybe_publish_pull_request(github_client, repository, run, branch, workspace_path, github_env) do
    if is_nil(branch) or branch == repository.default_branch do
      {:ok, nil}
    else
      publish_issue_branch_pull_request(
        github_client,
        repository,
        run,
        branch,
        workspace_path,
        github_env
      )
    end
  end

  defp publish_issue_branch_pull_request(
         github_client,
         repository,
         run,
         branch,
         workspace_path,
         github_env
       ) do
    title = pull_request_title(run)

    with {:ok, true} <- branch_has_delta(workspace_path, repository.default_branch),
         :ok <-
           ensure_remote_branch_synced(
             workspace_path,
             branch,
             repository.default_branch,
             github_env
           ),
         {:ok, body} <- PullRequestBody.build(workspace_path, repository, branch, run),
         {:ok, pull_request} <- github_client.find_open_pull_request(repository, branch) do
      publish_pull_request(github_client, repository, branch, title, body, pull_request)
    else
      {:ok, false} ->
        {:ok, nil}

      {:error, _reason} = error ->
        error
    end
  end

  defp publish_pull_request(github_client, repository, _branch, _title, body, %{number: number}) do
    github_client.update_pull_request(repository, number, nil, body)
  end

  defp publish_pull_request(github_client, repository, branch, title, body, nil) do
    github_client.create_pull_request(repository, branch, title, body)
  end

  defp branch_has_delta(workspace_path, default_branch) do
    case System.cmd("git", ["rev-list", "--count", "origin/#{default_branch}..HEAD"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case output |> String.trim() |> Integer.parse() do
          {count, ""} -> {:ok, count > 0}
          _ -> {:error, {:invalid_git_output, ["rev-list", "--count"], output}}
        end

      {output, status} ->
        {:error, {:git_command_failed, ["rev-list", "--count", "origin/#{default_branch}..HEAD"], status, output}}
    end
  end

  defp ensure_remote_branch_synced(workspace_path, branch, default_branch, env) do
    with {:ok, local_head} <- rev_parse(workspace_path, "HEAD"),
         {:ok, remote_head} <- remote_branch_head(workspace_path, branch, env),
         :ok <-
           ensure_branch_differs_from_default(
             workspace_path,
             branch,
             default_branch,
             local_head,
             env
           ) do
      if local_head == remote_head do
        :ok
      else
        {:error, {:issue_branch_out_of_sync, branch, local_head, remote_head}}
      end
    else
      {:error, :missing_remote_branch} ->
        {:error, {:issue_branch_not_pushed, branch}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_branch_differs_from_default(
         workspace_path,
         branch,
         default_branch,
         branch_head,
         env
       ) do
    case remote_branch_head(workspace_path, default_branch, env) do
      {:ok, default_head} when default_head == branch_head ->
        {:error, {:issue_branch_not_pushed, branch}}

      {:ok, _default_head} ->
        :ok

      {:error, :missing_remote_branch} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp remote_branch_head(workspace_path, branch, env) do
    case System.cmd("git", ["ls-remote", "--heads", "origin", branch],
           cd: workspace_path,
           stderr_to_stdout: true,
           env: env
         ) do
      {output, 0} ->
        case String.split(output, "\t", parts: 2) do
          [sha, _ref] when byte_size(sha) == 40 -> {:ok, sha}
          _ -> {:error, :missing_remote_branch}
        end

      {output, status} ->
        {:error, {:git_command_failed, ["ls-remote", "--heads", "origin", branch], status, output}}
    end
  end

  defp rev_parse(workspace_path, ref) do
    case System.cmd("git", ["rev-parse", ref], cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          <<sha::binary-size(40)>> -> {:ok, sha}
          trimmed -> {:error, {:invalid_git_output, ["rev-parse", ref], trimmed}}
        end

      {output, status} ->
        {:error, {:git_command_failed, ["rev-parse", ref], status, output}}
    end
  end

  defp pull_request_title(run) do
    identifier = run.linear_issue_identifier || run.linear_issue_id
    title = run.linear_issue_title || "Kepler change"
    "#{identifier}: #{title}"
  end

  defp current_branch(workspace_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: workspace_path, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> nil
          branch -> branch
        end

      _ ->
        nil
    end
  end

  defp expected_issue_branch(%Run{} = run, default_branch) when is_binary(default_branch) do
    case run.branch do
      branch
      when is_binary(branch) and branch != "" and branch != default_branch ->
        branch

      _ ->
        issue_token =
          case run.linear_issue_identifier || run.linear_issue_id do
            token when is_binary(token) and token != "" -> token
            _ -> "issue"
          end
          |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")

        "kepler/#{issue_token}"
    end
  end

  defp github_env(github_client, repository) do
    github_client.workspace_env(repository)
  end

  defp installation_id(github_client, repository) do
    case github_client.installation_auth(repository) do
      {:ok, %{installation_id: installation_id}} -> installation_id
      _ -> nil
    end
  end

  defp workspace_path(run, repository) do
    issue_token =
      run.linear_issue_identifier
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> run.linear_issue_id
      end
      |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")

    Path.join([Config.settings!().workspace.root, repository.id, issue_token])
  end

  defp reference_workspace_path(workspace_path, repository_id) do
    Path.join([workspace_path, ".kepler", "refs", repository_id])
  end

  defp clone_url(repository) do
    case repository.clone_url do
      <<"http", _::binary>> = url -> url
      <<"git@", _::binary>> -> "https://github.com/#{repository.full_name}.git"
      local_path when is_binary(local_path) -> local_path
    end
  end

  defp repository!(repository_id) do
    case Enum.find(Config.settings!().repositories, &(&1.id == repository_id)) do
      nil -> raise ArgumentError, "Unknown Kepler repository: #{inspect(repository_id)}"
      repository -> repository
    end
  end

  defp reference_repositories(repository) do
    by_id = Map.new(Config.settings!().repositories, &{&1.id, &1})

    repository.reference_repository_ids
    |> List.wrap()
    |> Enum.map(&Map.fetch!(by_id, &1))
  end

  defp github_client do
    Application.get_env(:symphony_elixir, :kepler_github_client_module, GitHubClient)
  end

  defp linear_client do
    Application.get_env(:symphony_elixir, :kepler_linear_client_module, SymphonyElixir.Kepler.Linear.Client)
  end

  defp app_server_module do
    Application.get_env(:symphony_elixir, :kepler_app_server_module, AppServer)
  end
end
