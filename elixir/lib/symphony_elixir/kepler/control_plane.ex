defmodule SymphonyElixir.Kepler.ControlPlane do
  @moduledoc """
  Kepler control plane for webhook intake, routing, execution, and recovery.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Execution.Runner
  alias SymphonyElixir.Kepler.Linear.Client, as: LinearClient
  alias SymphonyElixir.Kepler.Linear.Webhook
  alias SymphonyElixir.Kepler.Routing
  alias SymphonyElixir.Kepler.Run
  alias SymphonyElixir.Kepler.StateStore

  @default_retained_terminal_runs 200

  defmodule State do
    @moduledoc false

    defstruct [
      :settings,
      :dispatch_timer_ref,
      runs: %{},
      queued_run_ids: [],
      active_run_ids: [],
      task_refs: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @webhook_call_timeout_ms 15_000

  @type webhook_result :: :ok | {:error, {:invalid_payload, term()}} | {:error, :unavailable}

  @spec handle_webhook(map()) :: webhook_result()
  def handle_webhook(payload) when is_map(payload) do
    GenServer.call(__MODULE__, {:webhook, payload}, @webhook_call_timeout_ms)
  catch
    :exit, _reason ->
      {:error, :unavailable}
  end

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec request_refresh() :: :ok
  def request_refresh do
    GenServer.call(__MODULE__, :request_refresh)
  end

  @impl true
  def init(_opts) do
    settings = Config.settings!()
    state = load_state(settings)
    state = recover_interrupted_runs(state)
    state = schedule_dispatch(state, 0)
    Logger.info(
      "Kepler control plane ready repositories=#{length(settings.repositories)} " <>
        "auth_mode=#{inspect(SymphonyElixir.Kepler.Config.Schema.linear_auth_mode(settings.linear))} " <>
        "max_concurrent_runs=#{settings.limits.max_concurrent_runs}"
    )
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_payload(state), state}
  end

  def handle_call(:request_refresh, _from, state) do
    {:reply, :ok, schedule_dispatch(state, 0)}
  end

  def handle_call({:webhook, payload}, _from, state) do
    case handle_webhook_payload(state, payload) do
      {:ok, updated_state} ->
        {:reply, :ok, updated_state}

      {{:error, {:invalid_payload, _reason}} = error, updated_state} ->
        {:reply, error, updated_state}

      {{:error, :unavailable} = error, updated_state} ->
        {:reply, error, updated_state}
    end
  end

  @impl true
  def handle_info(:dispatch, state) do
    {:noreply, dispatch_runs(%{state | dispatch_timer_ref: nil})}
  end

  def handle_info({:run_event, run_id, message}, state) do
    emit_progress_activity(state, run_id, message)
    {:noreply, state}
  end

  def handle_info({:run_finished, run_id, {:ok, result}}, state) do
    {terminal_status, terminal_attrs} = terminal_result(result)

    {state, updated_run} =
      state
      |> finish_run(run_id, terminal_status, terminal_attrs)
      |> then(fn {updated_state, run} -> {schedule_dispatch(updated_state, 0), run} end)

    maybe_emit_terminal_activity(updated_run)
    {:noreply, state}
  end

  def handle_info({:run_finished, run_id, {:error, reason}}, state) do
    {state, updated_run} =
      state
      |> finish_run(run_id, "failed", %{last_error: inspect(reason), summary: nil})
      |> then(fn {updated_state, run} -> {schedule_dispatch(updated_state, 0), run} end)

    maybe_emit_terminal_activity(updated_run)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {run_id, task_refs} ->
        {:noreply, handle_run_down(state, task_refs, run_id, reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_webhook_payload(state, payload) do
    case Webhook.parse(payload) do
      {:ok, %{action: "created"} = event} ->
        intake_created_event(state, event)

      {:ok, %{action: "prompted"} = event} ->
        intake_prompted_event(state, event)

      {:error, reason} ->
        Logger.warning("Ignored invalid Linear webhook payload: #{inspect(reason)}")
        {{:error, {:invalid_payload, reason}}, state}
    end
  end

  defp intake_created_event(state, event) do
    if run_id_for_session(state, event.agent_session_id) do
      {:ok, state}
    else
      linear_client = linear_client_module()

      case linear_client.fetch_issue(event.issue_id) do
        {:ok, issue} ->
          maybe_create_run_from_issue(state, event, issue, linear_client)

        {:error, reason} ->
          Logger.warning("Failed to load issue context for Linear webhook: #{inspect(reason)}")
          {{:error, :unavailable}, state}
      end
    end
  end

  defp intake_prompted_event(state, event) do
    case run_id_for_session(state, event.agent_session_id) do
      nil ->
        case conflicting_issue_run(state, event.issue_id, event.agent_session_id) do
          %Run{status: "awaiting_repository_choice"} = existing_run ->
            continue_repository_choice_with_reconnected_session(state, existing_run, event)

          %Run{} = existing_run ->
            notify_issue_already_active(event.agent_session_id, existing_run)
            {:ok, state}

          nil ->
            {:ok, state}
        end

      run_id ->
        run = Map.fetch!(state.runs, run_id)
        handle_prompt_for_run(state, run, event.agent_session_id, event.prompt_body)
    end
  end

  defp create_run_from_issue(state, event, issue, linear_client) do
    case Routing.route_issue(issue, event.agent_session_id, linear_client) do
      {:resolved, routing_decision} ->
        repository = routing_decision.repository

        run =
          Run.new(%{
            linear_issue_id: issue.id,
            linear_issue_identifier: issue.identifier,
            linear_issue_title: issue.title,
            linear_issue_description: issue.description,
            linear_issue_url: issue.url,
            linear_agent_session_id: event.agent_session_id,
            repository_id: repository.id,
            repository_candidates: [repository.id],
            routing_source: routing_decision.source,
            routing_reason: routing_decision.reason,
            status: "queued",
            prompt_context: event.prompt_context,
            issue_labels: issue.labels,
            issue_team_key: issue.team_key,
            issue_project_id: issue.project_id,
            issue_project_slug: issue.project_slug
          })

        updated_state =
          state
          |> put_run(run)
          |> enqueue(run.id)

        persist_webhook_state(state, updated_state, fn persisted_state ->
          _ =
            linear_client.create_agent_activity(
              event.agent_session_id,
              thought("Acknowledged. Reviewing the issue and selecting a repository."),
              ephemeral: true
            )

          _ =
            linear_client.create_agent_activity(
              event.agent_session_id,
              thought("Selected repository `#{repository.full_name}` and queued execution."),
              ephemeral: true
            )

          persisted_state
          |> schedule_dispatch(0)
        end)

      {:ambiguous, repositories, reason} ->
        run =
          Run.new(%{
            linear_issue_id: issue.id,
            linear_issue_identifier: issue.identifier,
            linear_issue_title: issue.title,
            linear_issue_description: issue.description,
            linear_issue_url: issue.url,
            linear_agent_session_id: event.agent_session_id,
            repository_candidates: Enum.map(repositories, & &1.id),
            routing_reason: reason,
            status: "awaiting_repository_choice",
            prompt_context: event.prompt_context,
            issue_labels: issue.labels,
            issue_team_key: issue.team_key,
            issue_project_id: issue.project_id,
            issue_project_slug: issue.project_slug
          })

        updated_state =
          state
          |> put_run(run)

        persist_webhook_state(state, updated_state, fn persisted_state ->
          _ =
            linear_client.create_agent_activity(
              event.agent_session_id,
              thought("Acknowledged. Reviewing the issue and selecting a repository."),
              ephemeral: true
            )

          _ =
            linear_client.create_agent_activity(
              event.agent_session_id,
              elicitation(repositories, reason)
            )

          persisted_state
        end)
    end
  end

  defp resolve_repository_choice(state, run, prompt_body) do
    repositories = candidate_repositories(state, run.repository_candidates)

    case Routing.resolve_human_choice(prompt_body, repositories) do
      {:ok, repository} ->
        updated_run =
          run
          |> Run.touch(%{
            repository_id: repository.id,
            repository_candidates: [repository.id],
            routing_source: "human_choice",
            routing_reason: "User selected a repository from the elicitation choices.",
            status: "queued"
          })

        updated_state =
          state
          |> put_run(updated_run)
          |> enqueue(updated_run.id)

        persist_webhook_state(state, updated_state, fn persisted_state ->
          _ =
            linear_client_module().create_agent_activity(
              run.linear_agent_session_id,
              thought("Repository confirmed as `#{repository.full_name}`. Queued execution."),
              ephemeral: true
            )

          persisted_state
          |> schedule_dispatch(0)
        end)

      :error ->
        _ =
          linear_client_module().create_agent_activity(
            run.linear_agent_session_id,
            elicitation(repositories, "Please reply with one of the repository ids or full names listed above.")
          )

        {:ok, state}
    end
  end

  defp continue_repository_choice_with_reconnected_session(state, run, event) do
    updated_run = Run.touch(run, %{linear_agent_session_id: event.agent_session_id})
    updated_state = put_run(state, updated_run)

    persist_webhook_state(state, updated_state, fn persisted_state ->
      handle_prompt_for_run(
        persisted_state,
        updated_run,
        event.agent_session_id,
        event.prompt_body
      )
      |> case do
        {:ok, next_state} -> next_state
        {{:error, _reason}, next_state} -> next_state
      end
    end)
  end

  defp handle_prompt_for_run(state, run, agent_session_id, prompt_body) do
    prompt_body = prompt_body |> to_string() |> String.trim()

    cond do
      run.status == "awaiting_repository_choice" ->
        resolve_repository_choice(state, run, prompt_body)

      run.repository_id in [nil, ""] ->
        {:ok, state}

      prompt_body == "" ->
        {:ok, state}

      true ->
        queue_follow_up_prompt(state, agent_session_id, run, prompt_body)
    end
  end

  defp dispatch_runs(state) do
    available_slots = state.settings.limits.max_concurrent_runs - length(state.active_run_ids)

    dispatch_available_runs(state, available_slots)
  end

  defp dispatch_available_runs(state, available_slots) when available_slots <= 0, do: state

  defp dispatch_available_runs(state, available_slots) do
    Enum.reduce(1..available_slots, state, fn _, acc -> dispatch_next_run(acc) end)
  end

  defp dispatch_next_run(state) do
    case next_queued_run(state) do
      nil -> state
      run -> launch_run(state, run)
    end
  end

  defp next_queued_run(state) do
    Enum.find_value(state.queued_run_ids, fn run_id ->
      case Map.get(state.runs, run_id) do
        %Run{status: "queued"} = run -> run
        _ -> nil
      end
    end)
  end

  defp launch_run(state, %Run{} = run) do
    parent = self()
    runner_module = execution_runner_module()
    workspace_path = predicted_workspace_path(state, run)

    execution_run =
      run
      |> Run.touch(%{
        status: "executing",
        workspace_path: workspace_path,
        active_follow_up_prompts: run.follow_up_prompts,
        follow_up_prompts: []
      })

    {:ok, pid} =
      Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
        result =
          runner_module.run(execution_run,
            on_event: fn message -> send(parent, {:run_event, run.id, message}) end
          )

        send(parent, {:run_finished, run.id, result})
      end)

    ref = Process.monitor(pid)

    updated_state =
      state
      |> put_run(execution_run)
      |> dequeue(execution_run.id)
      |> add_active(execution_run.id)
      |> put_task_ref(ref, execution_run.id)
      |> persist_state()

    maybe_transition_issue_state(execution_run, executing_state_name())
    updated_state
  end

  defp finish_run(state, run_id, status, attrs) do
    case Map.get(state.runs, run_id) do
      nil ->
        {state, nil}

      %Run{} = run ->
        final_status =
          if status in ["completed", "failed", "cancelled"] and run.follow_up_prompts != [] do
            "queued"
          else
            status
          end

        final_attrs =
          attrs
          |> Map.put(:status, final_status)
          |> Map.put(:active_follow_up_prompts, [])
          |> maybe_clear_summary(final_status)

        updated_run =
          run
          |> Run.touch(final_attrs)

        updated_state =
          state
          |> put_run(updated_run)
          |> remove_active(run_id)
          |> drop_task_ref(run_id)
          |> maybe_update_queue(updated_run)
          |> persist_state()

        {updated_state, updated_run}
    end
  end

  defp maybe_emit_terminal_activity(%Run{status: "completed"} = run) do
    _ =
      linear_client_module().create_agent_activity(
        run.linear_agent_session_id,
        response(completed_response_body(run))
      )

    maybe_attach_pull_request(run)
    maybe_transition_issue_state_for_completed_run(run)
  end

  defp maybe_emit_terminal_activity(%Run{status: "failed"} = run) do
    _ =
      linear_client_module().create_agent_activity(
        run.linear_agent_session_id,
        error(failed_response_body(run))
      )

    maybe_transition_issue_state(run, blocked_state_name())
  end

  defp maybe_emit_terminal_activity(%Run{status: "queued"} = run) do
    _ =
      linear_client_module().create_agent_activity(
        run.linear_agent_session_id,
        thought("Queued another execution cycle to apply the latest follow-up prompt.")
      )
  end

  defp maybe_emit_terminal_activity(_run), do: :ok

  defp completed_response_body(%Run{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp completed_response_body(_run), do: "Run completed."

  defp failed_response_body(%Run{last_error: last_error, summary: summary})
       when is_binary(last_error) and last_error != "" and is_binary(summary) and summary != "" do
    """
    Run failed: #{last_error}

    #{summary}
    """
    |> String.trim()
  end

  defp failed_response_body(%Run{last_error: last_error}) when is_binary(last_error) and last_error != "",
    do: "Run failed: #{last_error}"

  defp failed_response_body(%Run{summary: summary}) when is_binary(summary) and summary != "",
    do: summary

  defp failed_response_body(_run), do: "Run failed."

  defp maybe_clear_summary(attrs, "queued"), do: Map.put(attrs, :summary, nil)
  defp maybe_clear_summary(attrs, _status), do: attrs

  defp terminal_result(result) do
    base_attrs = %{
      branch: result.branch,
      github_installation_id: result.github_installation_id,
      pr_url: result.pr_url,
      summary: result.summary,
      workspace_path: result.workspace_path
    }

    case result.pr_url do
      value when is_binary(value) and value != "" ->
        {"completed", Map.put(base_attrs, :last_error, nil)}

      _ ->
        {"failed",
         Map.put(
           base_attrs,
           :last_error,
           "Run finished without opening a pull request. Kepler requires a PR for every ticket unless it explicitly asks for more input or repository clarification."
         )}
    end
  end

  defp handle_run_down(state, task_refs, run_id, reason) do
    run = Map.get(state.runs, run_id)

    if run && run.status in ["executing", "publishing", "preparing_workspace"] do
      {updated_state, updated_run} =
        state
        |> Map.put(:task_refs, task_refs)
        |> finish_run(run_id, "failed", %{last_error: "run exited unexpectedly: #{inspect(reason)}"})
        |> then(fn {next_state, finished_run} -> {schedule_dispatch(next_state, 0), finished_run} end)

      maybe_emit_terminal_activity(updated_run)
      updated_state
    else
      %{state | task_refs: task_refs}
    end
  end

  defp predicted_workspace_path(state, %Run{} = run) do
    case {run.repository_id, run.linear_issue_identifier || run.linear_issue_id} do
      {repository_id, issue_token}
      when is_binary(repository_id) and repository_id != "" and is_binary(issue_token) and issue_token != "" ->
        repository = Enum.find(state.settings.repositories, &(&1.id == repository_id))

        if repository do
          safe_issue_token = String.replace(issue_token, ~r/[^a-zA-Z0-9._-]/, "_")
          Path.join([state.settings.workspace.root, repository.id, safe_issue_token])
        end

      _ ->
        nil
    end
  end

  defp conflicting_issue_run(state, issue_id, agent_session_id) when is_binary(issue_id) do
    Enum.find_value(state.runs, fn {_run_id, run} ->
      if run.linear_issue_id == issue_id and run.linear_agent_session_id != agent_session_id and
           not terminal_run?(run) do
        run
      end
    end)
  end

  defp conflicting_issue_run(_state, _issue_id, _agent_session_id), do: nil

  defp maybe_create_run_from_issue(state, event, issue, linear_client) do
    case conflicting_issue_run(state, issue.id, event.agent_session_id) do
      nil ->
        create_run_from_issue(state, event, issue, linear_client)

      %Run{} = existing_run ->
        notify_issue_already_active(event.agent_session_id, existing_run)
        {:ok, state}
    end
  end

  defp notify_issue_already_active(agent_session_id, %Run{} = existing_run) do
    client = linear_client_module()

    _ =
      client.create_agent_activity(
        agent_session_id,
        thought("This Linear issue already has an active Kepler run in another session. Reuse the existing session or wait for it to finish before creating a new one."),
        ephemeral: true
      )

    if existing_run.pr_url do
      _ =
        client.update_agent_session(agent_session_id, %{
          externalUrls: [
            %{
              label: "Existing Pull Request",
              url: existing_run.pr_url
            }
          ]
        })
    end

    :ok
  end

  defp emit_progress_activity(state, run_id, message) do
    case Map.get(state.runs, run_id) do
      %Run{} = run ->
        case progress_activity(message) do
          nil ->
            :ok

          activity ->
            linear_client_module().create_agent_activity(
              run.linear_agent_session_id,
              activity,
              ephemeral: true
            )
        end

      _ ->
        :ok
    end
  end

  defp queue_follow_up_prompt(state, agent_session_id, run, prompt_body) do
    updated_run =
      run
      |> Run.touch(%{
        follow_up_prompts: run.follow_up_prompts ++ [prompt_body],
        status:
          if(run.status in ["completed", "failed", "cancelled"],
            do: "queued",
            else: run.status
          )
      })

    updated_state =
      state
      |> put_run(updated_run)
      |> maybe_enqueue(updated_run.id)

    persist_webhook_state(state, updated_state, fn persisted_state ->
      _ =
        linear_client_module().create_agent_activity(
          agent_session_id,
          thought("Captured the follow-up prompt and queued it for the next execution cycle."),
          ephemeral: true
        )

      persisted_state
      |> schedule_dispatch(0)
    end)
  end

  defp progress_activity(%{event: :session_started}) do
    thought("Codex session started.")
  end

  defp progress_activity(%{event: :tool_call_completed, details: %{payload: %{"params" => params}}}) do
    %{
      type: "action",
      action: "Used tool",
      parameter: tool_parameter(params)
    }
  end

  defp progress_activity(%{event: :approval_required}) do
    error("Codex requested interactive approval, which is not available in hosted mode.")
  end

  defp progress_activity(%{event: :turn_ended_with_error, details: %{reason: reason}}) do
    error("Codex turn ended with an error: #{inspect(reason)}")
  end

  defp progress_activity(_message), do: nil

  defp tool_parameter(%{"toolCall" => %{"name" => name}}) when is_binary(name), do: name
  defp tool_parameter(_params), do: "dynamic tool"

  defp maybe_attach_pull_request(%Run{pr_url: nil}), do: :ok

  defp maybe_attach_pull_request(%Run{} = run) do
    client = linear_client_module()

    session_result =
      client.update_agent_session(run.linear_agent_session_id, %{
        externalUrls: [
          %{
            label: "Pull Request",
            url: run.pr_url
          }
        ]
      })

    attachment_result =
      client.create_issue_attachment(run.linear_issue_id, %{
        title: "Pull Request",
        subtitle: pull_request_attachment_subtitle(run),
        url: run.pr_url,
        metadata: %{
          branch: run.branch,
          issueIdentifier: run.linear_issue_identifier,
          repositoryId: run.repository_id
        }
      })

    maybe_log_pull_request_link_failure(run, :session_external_url, session_result)
    maybe_log_pull_request_link_failure(run, :issue_attachment, attachment_result)
    :ok
  end

  defp maybe_transition_issue_state_for_completed_run(%Run{pr_url: nil}), do: :ok

  defp maybe_transition_issue_state_for_completed_run(%Run{} = run) do
    maybe_transition_issue_state(run, review_state_name())
  end

  defp pull_request_attachment_subtitle(%Run{branch: branch}) when is_binary(branch) and branch != "",
    do: "Open on #{branch}"

  defp pull_request_attachment_subtitle(_run), do: "Open"

  defp maybe_log_pull_request_link_failure(_run, _target, :ok), do: :ok

  defp maybe_log_pull_request_link_failure(run, target, {:error, reason}) do
    Logger.warning("Failed to link pull request for Kepler run #{run.id} target=#{target}: #{inspect(reason)}")
  end

  defp maybe_transition_issue_state(_run, nil), do: :ok
  defp maybe_transition_issue_state(_run, ""), do: :ok

  defp maybe_transition_issue_state(%Run{} = run, state_name) do
    case linear_client_module().update_issue_state(run.linear_issue_id, state_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to transition Linear issue #{run.linear_issue_identifier || run.linear_issue_id} to #{inspect(state_name)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp executing_state_name do
    linear_settings().executing_state_name
  end

  defp review_state_name do
    linear_settings().review_state_name
  end

  defp blocked_state_name do
    linear_settings().blocked_state_name
  end

  defp linear_settings do
    Config.settings!().linear
  end

  defp thought(body), do: %{type: "thought", body: body}
  defp response(body), do: %{type: "response", body: body}
  defp error(body), do: %{type: "error", body: body}

  defp elicitation(repositories, reason) do
    choices =
      repositories
      |> Enum.map_join("\n", fn repository ->
        "- `#{repository.id}` (`#{repository.full_name}`)"
      end)

    %{
      type: "elicitation",
      body: """
      #{reason}

      Reply with one of:
      #{choices}
      """
    }
  end

  defp snapshot_payload(state) do
    %{
      mode: "kepler",
      queued_count: length(state.queued_run_ids),
      active_count: length(state.active_run_ids),
      run_count: map_size(state.runs),
      runs:
        state.runs
        |> Map.values()
        |> Enum.sort_by(&{&1.updated_at, &1.id}, :desc)
    }
  end

  defp candidate_repositories(state, repository_ids) do
    state.settings.repositories
    |> Enum.filter(&(&1.id in repository_ids))
  end

  defp run_id_for_session(state, agent_session_id) do
    Enum.find_value(state.runs, fn {run_id, run} ->
      if run.linear_agent_session_id == agent_session_id, do: run_id, else: nil
    end)
  end

  defp load_state(settings) do
    case state_store_module().load(settings) do
      {:ok, payload} ->
        %State{
          settings: settings,
          runs: StateStore.decode_runs(payload),
          queued_run_ids: Map.get(payload, "queued_run_ids", []),
          active_run_ids: Map.get(payload, "active_run_ids", []),
          task_refs: %{}
        }

      {:error, reason} ->
        Logger.warning("Failed to load Kepler state, starting empty: #{inspect(reason)}")
        %State{settings: settings}
    end
  end

  defp recover_interrupted_runs(state) do
    recovered_state =
      state
      |> reset_recovery_scheduler_state()
      |> then(&Enum.reduce(&1.runs, &1, fn {run_id, run}, acc -> recover_run(acc, run_id, run) end))

    persist_state(recovered_state)
  end

  defp recover_run(state, run_id, run) do
    cond do
      Run.recoverable?(run) ->
        restored_prompts = run.active_follow_up_prompts ++ run.follow_up_prompts

        state
        |> put_run(
          Run.touch(run, %{
            status: "queued",
            last_error: "Recovered after service restart.",
            active_follow_up_prompts: [],
            follow_up_prompts: restored_prompts
          })
        )
        |> maybe_enqueue(run_id)

      Run.interrupted?(run) ->
        state
        |> put_run(
          Run.touch(run, %{
            status: "interrupted",
            last_error: "Interrupted by service restart.",
            active_follow_up_prompts: []
          })
        )
        |> dequeue(run_id)
        |> remove_active(run_id)

      true ->
        state
    end
  end

  defp reset_recovery_scheduler_state(state) do
    valid_run_ids = Map.keys(state.runs) |> MapSet.new()

    %{
      state
      | queued_run_ids:
          state.queued_run_ids
          |> Enum.filter(&MapSet.member?(valid_run_ids, &1))
          |> Enum.uniq(),
        active_run_ids: []
    }
  end

  defp schedule_dispatch(state, delay_ms) do
    if state.dispatch_timer_ref, do: Process.cancel_timer(state.dispatch_timer_ref)
    %{state | dispatch_timer_ref: Process.send_after(self(), :dispatch, delay_ms)}
  end

  defp persist_state(state) do
    case save_state(state) do
      {:ok, persisted_state} ->
        persisted_state

      {:error, reason} ->
        Logger.warning("Failed to persist Kepler state: #{inspect(reason)}")
        state
    end
  end

  defp persist_webhook_state(original_state, updated_state, on_success)
       when is_function(on_success, 1) do
    case save_state(updated_state) do
      {:ok, persisted_state} ->
        {:ok, on_success.(persisted_state)}

      {:error, reason} ->
        Logger.warning("Failed to persist Kepler webhook state: #{inspect(reason)}")
        {{:error, :unavailable}, original_state}
    end
  end

  defp save_state(state) do
    state_to_persist = prune_terminal_runs(state)

    payload = %{
      "runs" => StateStore.encode_runs(state_to_persist.runs),
      "queued_run_ids" => state_to_persist.queued_run_ids,
      "active_run_ids" => state_to_persist.active_run_ids
    }

    case state_store_module().save(state_to_persist.settings, payload) do
      :ok ->
        {:ok, state_to_persist}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prune_terminal_runs(state) do
    retention_limit = retained_terminal_run_limit()
    terminal_runs = Enum.filter(Map.values(state.runs), &terminal_run?/1)

    retained_terminal_ids =
      terminal_runs
      |> Enum.sort_by(&{&1.updated_at, &1.id}, :desc)
      |> Enum.take(retention_limit)
      |> MapSet.new(& &1.id)

    retained_runs =
      state.runs
      |> Enum.filter(fn {run_id, run} ->
        not terminal_run?(run) or MapSet.member?(retained_terminal_ids, run_id)
      end)
      |> Map.new()

    retained_run_ids = Map.keys(retained_runs) |> MapSet.new()

    retained_task_refs =
      state.task_refs
      |> Enum.filter(fn {_ref, run_id} -> MapSet.member?(retained_run_ids, run_id) end)
      |> Map.new()

    %{
      state
      | runs: retained_runs,
        queued_run_ids: Enum.filter(state.queued_run_ids, &MapSet.member?(retained_run_ids, &1)),
        active_run_ids: Enum.filter(state.active_run_ids, &MapSet.member?(retained_run_ids, &1)),
        task_refs: retained_task_refs
    }
  end

  defp terminal_run?(%Run{status: status}) do
    status in ["completed", "failed", "cancelled", "interrupted"]
  end

  defp retained_terminal_run_limit do
    Application.get_env(
      :symphony_elixir,
      :kepler_retained_terminal_runs,
      @default_retained_terminal_runs
    )
  end

  defp put_run(state, %Run{} = run) do
    %{state | runs: Map.put(state.runs, run.id, run)}
  end

  defp enqueue(state, run_id) do
    %{state | queued_run_ids: state.queued_run_ids ++ [run_id]}
  end

  defp maybe_enqueue(state, run_id) do
    if run_id in state.queued_run_ids, do: state, else: enqueue(state, run_id)
  end

  defp maybe_update_queue(state, %Run{id: run_id, status: "queued"}) do
    maybe_enqueue(state, run_id)
  end

  defp maybe_update_queue(state, %Run{id: run_id}) do
    dequeue(state, run_id)
  end

  defp dequeue(state, run_id) do
    %{state | queued_run_ids: Enum.reject(state.queued_run_ids, &(&1 == run_id))}
  end

  defp add_active(state, run_id) do
    %{state | active_run_ids: state.active_run_ids ++ [run_id]}
  end

  defp remove_active(state, run_id) do
    %{state | active_run_ids: Enum.reject(state.active_run_ids, &(&1 == run_id))}
  end

  defp put_task_ref(state, ref, run_id) do
    %{state | task_refs: Map.put(state.task_refs, ref, run_id)}
  end

  defp drop_task_ref(state, run_id) do
    task_refs =
      state.task_refs
      |> Enum.reject(fn {_ref, current_run_id} -> current_run_id == run_id end)
      |> Map.new()

    %{state | task_refs: task_refs}
  end

  defp linear_client_module do
    Application.get_env(:symphony_elixir, :kepler_linear_client_module, LinearClient)
  end

  defp execution_runner_module do
    Application.get_env(:symphony_elixir, :kepler_execution_runner_module, Runner)
  end

  defp state_store_module do
    Application.get_env(:symphony_elixir, :kepler_state_store_module, StateStore)
  end
end
