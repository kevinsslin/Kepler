defmodule SymphonyElixir.Kepler.WorkflowResolver do
  @moduledoc """
  Resolves repository-local workflow files with a Kepler fallback template.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Workflow

  @hosted_prompt_prefix """
  Hosted Kepler operator rules:

  - All outward-facing artifacts for this run must be written in English, regardless of the issue language. This includes `.kepler/workpad.md`, `.kepler/pr-report.json` text fields, the final agent response, commit messages, and PR title/body text.
  - `.kepler/workpad.md` is mirrored into a single persistent Linear issue comment. Keep it concise, reviewer-facing, and updated in place.
  - Do not keep a chronological diary or repeat micro-updates. Replace stale checklist items and notes in place instead of appending long narrative paragraphs.
  - Do not include container hostnames, internal workspace paths (e.g. `/data/workspaces/...`), or runtime identity markers in `.kepler/workpad.md`. The workpad is reviewer-facing; only include information a human PR reviewer can act on.
  - Do not paste raw local filesystem paths for screenshot evidence into `.kepler/workpad.md`. Keep local screenshot paths in `.kepler/pr-report.json`; in the workpad, summarize the evidence briefly in English.
  - Keep screenshot previews and renderable evidence in the pull request, not in the Linear workpad comment.
  """

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
         workflow: prepend_hosted_prompt_rules(workflow),
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

  defp prepend_hosted_prompt_rules(%{prompt: prompt, prompt_template: prompt_template} = workflow) do
    prefix = String.trim(@hosted_prompt_prefix)

    %{
      workflow
      | prompt: Enum.join([prefix, String.trim(prompt)], "\n\n"),
        prompt_template: Enum.join([prefix, String.trim(prompt_template)], "\n\n")
    }
  end
end
