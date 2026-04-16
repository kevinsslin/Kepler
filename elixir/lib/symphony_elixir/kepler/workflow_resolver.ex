defmodule SymphonyElixir.Kepler.WorkflowResolver do
  @moduledoc """
  Resolves repository-local workflow files with a Kepler fallback template.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Workflow

  @type resolved_workflow :: %{
          workflow: Workflow.loaded_workflow(),
          settings: Schema.t(),
          workflow_path: Path.t()
        }

  @spec load(Path.t(), SymphonyElixir.Kepler.Config.Schema.Repository.t()) ::
          {:ok, resolved_workflow()} | {:error, term()}
  def load(workspace, repository) when is_binary(workspace) do
    repo_workflow_path = Path.join(workspace, repository.workflow_path)

    chosen_path =
      if File.regular?(repo_workflow_path) do
        repo_workflow_path
      else
        Config.settings!().routing.fallback_workflow_path
      end

    with {:ok, workflow} <- Workflow.load(chosen_path),
         {:ok, settings} <- Schema.parse(workflow.config) do
      {:ok,
       %{
         workflow: workflow,
         settings: normalize_settings(settings),
         workflow_path: chosen_path
       }}
    end
  end

  defp normalize_settings(settings) do
    kepler_settings = Config.settings!()
    workspace_root = kepler_settings.workspace.root
    hosted_codex = kepler_settings.codex

    %{
      settings
      | workspace: %{settings.workspace | root: workspace_root},
        worker: %{settings.worker | ssh_hosts: []},
        codex: %{
          settings.codex
          | thread_sandbox: hosted_codex.thread_sandbox,
            turn_sandbox_policy: hosted_codex.turn_sandbox_policy
        }
    }
  end
end
