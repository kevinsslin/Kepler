defmodule SymphonyElixir.KeplerTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.ControlPlane
  alias SymphonyElixir.Kepler.Run
  alias SymphonyElixir.Kepler.StateStore
  alias SymphonyElixir.RuntimeMode

  defmodule FakeLinearClient do
    alias SymphonyElixir.Kepler.Linear.IssueContext

    @spec fetch_issue(String.t()) :: {:ok, IssueContext.t()}
    def fetch_issue(issue_id) do
      issue =
        :persistent_term.get({__MODULE__, :issue}, nil) ||
          %IssueContext{
            id: issue_id,
            identifier: "KEP-1",
            title: "Implement Kepler",
            description: "Hosted execution",
            labels: ["backend"],
            team_key: "ENG",
            project_slug: "kepler"
          }

      {:ok, %{issue | id: issue_id}}
    end

    @spec suggest_repositories(String.t(), String.t(), [map()]) :: {:ok, [map()]}
    def suggest_repositories(_issue_id, _agent_session_id, _candidate_repositories) do
      {:ok, :persistent_term.get({__MODULE__, :suggestions}, [])}
    end

    @spec create_agent_activity(String.t(), map(), keyword()) :: :ok
    def create_agent_activity(agent_session_id, content, _opts \\ []) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, {:activity, agent_session_id, content})
      end

      :ok
    end

    @spec update_agent_session(String.t(), map()) :: :ok
    def update_agent_session(agent_session_id, input) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, {:session_update, agent_session_id, input})
      end

      :ok
    end

    @spec create_issue_attachment(String.t(), map()) :: :ok
    def create_issue_attachment(issue_id, input) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, {:issue_attachment, issue_id, input})
      end

      :ok
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok
    def update_issue_state(issue_id, state_name) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, {:issue_state_update, issue_id, state_name})
      end

      :ok
    end

    @spec create_issue_comment(String.t(), String.t()) :: {:ok, String.t()}
    def create_issue_comment(issue_id, body) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        comment_id = "comment-" <> Integer.to_string(System.unique_integer([:positive]))
        send(recipient, {:issue_comment_create, issue_id, comment_id, body})
        {:ok, comment_id}
      else
        {:ok, "comment-test"}
      end
    end

    @spec update_issue_comment(String.t(), String.t()) :: :ok
    def update_issue_comment(comment_id, body) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(recipient, {:issue_comment_update, comment_id, body})
      end

      :ok
    end

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()}
    def graphql(_query, _variables, _opts \\ []), do: {:ok, %{}}
  end

  defmodule FakeRunner do
    alias SymphonyElixir.Kepler.Run

    def default_workpad_markdown do
      """
      ## Kepler Workpad

      ### Plan

      - [ ] Inspect the selected repository
      - [ ] Implement the requested code change

      ### Acceptance Criteria

      - [ ] Requested behavior is implemented
      """
      |> String.trim()
    end

    @spec run(Run.t(), keyword()) :: {:ok, map()}
    def run(run, opts \\ []) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(
          recipient,
          {:runner_run, run.repository_id, run.linear_agent_session_id, run.active_follow_up_prompts}
        )
      end

      on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

      events =
        case :persistent_term.get({__MODULE__, :events}, :unset) do
          :unset -> default_events()
          nil -> default_events()
          configured_events -> configured_events
        end

      Enum.each(events, on_event)

      case :persistent_term.get({__MODULE__, :release}, :immediate) do
        :immediate ->
          :ok

        {:block, pid} ->
          ref = make_ref()
          send(pid, {:runner_waiting, run.linear_agent_session_id, ref, self()})

          receive do
            {:release_runner, ^ref} -> :ok
          after
            2_000 -> :ok
          end

        {:block_once, pid, ref} ->
          send(pid, {:runner_waiting, run.linear_agent_session_id, ref, self()})

          receive do
            {:release_runner, ^ref} ->
              :persistent_term.put({__MODULE__, :release}, :immediate)
              :ok
          after
            2_000 -> :ok
          end
      end

      result =
        :persistent_term.get({__MODULE__, :result}, %{
          branch: "kepler/#{run.linear_issue_identifier}",
          github_installation_id: 99,
          pr_url: "https://github.com/example/#{run.repository_id}/pull/1",
          summary: "Run complete for #{run.repository_id}",
          workpad_markdown: default_workpad_markdown(),
          workspace_path: "/tmp/#{run.repository_id}"
        })

      {:ok, result}
    end

    defp default_events do
      [
        %{event: :session_started, details: %{session_id: "fake-session"}},
        %{
          event: :workpad_snapshot,
          details: %{markdown: default_workpad_markdown()}
        },
        %{
          event: :notification,
          payload: %{
            "method" => "item/agentMessage/delta",
            "params" => %{
              "delta" => "Inspect the selected repository, make the requested code change, and open a pull request once the diff is ready."
            }
          }
        },
        %{
          event: :tool_call_completed,
          details: %{payload: %{"params" => %{"tool" => "linear_graphql"}}}
        }
      ]
    end
  end

  defmodule FailingStateStore do
    def load(_settings), do: {:ok, StateStore.empty_payload()}
    def save(_settings, _payload), do: {:error, :simulated_persistence_failure}
  end

  setup do
    config_root =
      Path.join(
        System.tmp_dir!(),
        "kepler-test-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(config_root, "kepler.yml")
    File.mkdir_p!(config_root)
    write_kepler_config!(config_path, config_root)

    original_runtime_mode = Application.get_env(:symphony_elixir, :runtime_mode)
    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_linear_client = Application.get_env(:symphony_elixir, :kepler_linear_client_module)
    original_runner = Application.get_env(:symphony_elixir, :kepler_execution_runner_module)
    original_state_store = Application.get_env(:symphony_elixir, :kepler_state_store_module)
    original_retained_terminal_runs = Application.get_env(:symphony_elixir, :kepler_retained_terminal_runs)
    original_fake_linear_issue = persistent_get({FakeLinearClient, :issue})
    original_fake_linear_suggestions = persistent_get({FakeLinearClient, :suggestions})
    original_fake_linear_recipient = persistent_get({FakeLinearClient, :recipient})
    original_fake_runner_recipient = persistent_get({FakeRunner, :recipient})
    original_fake_runner_release = persistent_get({FakeRunner, :release})
    original_fake_runner_result = persistent_get({FakeRunner, :result})
    original_fake_runner_events = persistent_get({FakeRunner, :events})
    original_github_token = System.get_env("GITHUB_TOKEN")

    RuntimeMode.set(:kepler)
    Config.set_config_file_path(config_path)
    Application.put_env(:symphony_elixir, :kepler_linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :kepler_execution_runner_module, FakeRunner)
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    persistent_put({FakeLinearClient, :recipient}, self())
    persistent_put({FakeRunner, :recipient}, self())
    persistent_put({FakeRunner, :release}, :immediate)
    persistent_put({FakeRunner, :events}, nil)

    persistent_put({FakeRunner, :result}, %{
      branch: "kepler/KEP-1",
      codex_result: %{
        final_agent_message: "Implemented the requested change and prepared the pull request."
      },
      github_installation_id: 99,
      pr_url: "https://github.com/example/repo-api/pull/1",
      summary: "Run complete for repo-api",
      workspace_path: "/tmp/repo-api"
    })

    persistent_put({FakeLinearClient, :suggestions}, [])

    start_supervised!(ControlPlane)

    on_exit(fn ->
      if is_nil(original_runtime_mode) do
        Application.delete_env(:symphony_elixir, :runtime_mode)
      else
        Application.put_env(:symphony_elixir, :runtime_mode, original_runtime_mode)
      end

      if is_nil(original_config_path),
        do: Config.clear_config_file_path(),
        else: Config.set_config_file_path(original_config_path)

      if is_nil(original_linear_client) do
        Application.delete_env(:symphony_elixir, :kepler_linear_client_module)
      else
        Application.put_env(:symphony_elixir, :kepler_linear_client_module, original_linear_client)
      end

      if is_nil(original_runner) do
        Application.delete_env(:symphony_elixir, :kepler_execution_runner_module)
      else
        Application.put_env(:symphony_elixir, :kepler_execution_runner_module, original_runner)
      end

      restore_app_env(:kepler_state_store_module, original_state_store)
      restore_app_env(:kepler_retained_terminal_runs, original_retained_terminal_runs)

      persistent_restore({FakeLinearClient, :issue}, original_fake_linear_issue)
      persistent_restore({FakeLinearClient, :suggestions}, original_fake_linear_suggestions)
      persistent_restore({FakeLinearClient, :recipient}, original_fake_linear_recipient)
      persistent_restore({FakeRunner, :recipient}, original_fake_runner_recipient)
      persistent_restore({FakeRunner, :release}, original_fake_runner_release)
      persistent_restore({FakeRunner, :result}, original_fake_runner_result)
      persistent_restore({FakeRunner, :events}, original_fake_runner_events)
      restore_env("GITHUB_TOKEN", original_github_token)

      File.rm_rf(config_root)
    end)

    %{config_root: config_root, config_path: config_path}
  end

  test "run ids use UUIDs instead of process-local counters" do
    run_one = Run.new(%{linear_issue_id: "issue-uuid-1", linear_agent_session_id: "session-uuid-1"})
    run_two = Run.new(%{linear_issue_id: "issue-uuid-2", linear_agent_session_id: "session-uuid-2"})

    assert run_one.id =~ ~r/^run-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    assert run_two.id =~ ~r/^run-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    refute run_one.id == run_two.id
  end

  test "created webhook routes explicitly matched repository and completes the run" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-1",
        identifier: "KEP-42",
        title: "Fix router",
        description: "Hosted mode",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-1",
                   "issue" => %{"id" => "issue-1"},
                   "promptContext" => "Please fix the router."
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:issue_state_update, "issue-1", "In Progress"}
    assert_receive {:issue_comment_create, "issue-1", comment_id, started_comment}
    assert started_comment =~ "## Kepler Workpad"
    assert started_comment =~ "Status: `executing`"
    assert started_comment =~ "Repository: `example/repo-api`"
    assert started_comment =~ "Branch: `"
    assert started_comment =~ "KEP-42`"
    refute started_comment =~ "## Kepler Workpad\n\n---\n\n## Kepler Workpad"
    assert started_comment =~ "Inspect the selected repository"
    assert_receive {:activity, "session-1", %{type: "thought", body: body}}
    assert body =~ "Acknowledged"
    assert_receive {:runner_run, "repo-api", "session-1", []}
    assert_receive {:issue_state_update, "issue-1", "In Review"}
    finished_comment = assert_receive_comment_update(comment_id, &String.contains?(&1, "Status: `completed`"))
    assert finished_comment =~ "## Kepler Workpad"
    assert finished_comment =~ "Status: `completed`"
    assert finished_comment =~ "Pull request: attached to the issue"
    refute finished_comment =~ "## Kepler Workpad\n\n---\n\n## Kepler Workpad"
    assert_receive {:session_update, "session-1", %{externalUrls: [%{label: "Pull Request", url: pr_url}]}}
    assert pr_url =~ "repo-api"
    assert_receive {:issue_attachment, "issue-1", %{title: "Pull Request", url: ^pr_url}}

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "completed", repository_id: "repo-api", pr_url: pr_url}] = snapshot.runs
      assert pr_url =~ "repo-api"
    end)
  end

  test "prompted webhook resolves an ambiguous repository choice" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-2",
        identifier: "KEP-77",
        title: "Ambiguous route",
        description: "Needs choice",
        labels: ["unknown"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-2",
                   "issue" => %{"id" => "issue-2"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-2", %{type: "elicitation", body: body}}
    assert body =~ "Reply with one of"

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "prompted",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-2",
                   "issue" => %{"id" => "issue-2"}
                 },
                 "prompt" => %{"body" => "repo-web"},
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "completed", repository_id: "repo-web"}] = snapshot.runs
    end)
  end

  test "prompted webhook accepts rendered repository choice lines" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-choice-line",
        identifier: "KEP-77B",
        title: "Ambiguous route line reply",
        description: "Needs choice",
        labels: ["unknown"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-choice-line",
                   "issue" => %{"id" => "issue-choice-line"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-choice-line", %{type: "elicitation", body: body}}
    assert body =~ "Reply with one of"

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "prompted",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-choice-line",
                   "issue" => %{"id" => "issue-choice-line"}
                 },
                 "prompt" => %{"body" => "`repo-web` (`example/repo-web`)"},
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()

      [%{status: "completed", repository_id: "repo-web"}] =
        Enum.filter(snapshot.runs, &(&1.linear_issue_id == "issue-choice-line"))
    end)
  end

  test "prompted webhook can resume repository choice from a reconnected session" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-reconnect",
        identifier: "KEP-77C",
        title: "Reconnect choice",
        description: "Needs choice after reconnect",
        labels: ["unknown"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-reconnect-old",
                   "issue" => %{"id" => "issue-reconnect"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-reconnect-old", %{type: "elicitation", body: body}}
    assert body =~ "Reply with one of"

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "prompted",
               "agentSession" => %{
                 "id" => "session-reconnect-new",
                 "issue" => %{"id" => "issue-reconnect"}
               },
               "agentActivity" => %{"content" => %{"body" => "repo-web"}},
               "webhookTimestamp" => System.system_time(:millisecond)
             })

    assert_receive {:activity, "session-reconnect-new", %{type: "thought", body: confirmed_body}}
    assert confirmed_body =~ "Repository confirmed"
    assert_receive {:runner_run, "repo-web", "session-reconnect-new", []}

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()

      [%{status: "completed", repository_id: "repo-web", linear_agent_session_id: "session-reconnect-new"}] =
        Enum.filter(snapshot.runs, &(&1.linear_issue_id == "issue-reconnect"))
    end)
  end

  test "follow-up prompts received during execution queue another run and are applied once" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-3",
        identifier: "KEP-88",
        title: "Add logging",
        description: "Needs follow-up",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-3",
                   "issue" => %{"id" => "issue-3"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-3", %{type: "thought", body: ack_body}}
    assert ack_body =~ "Acknowledged"
    assert_receive {:activity, "session-3", %{type: "thought", body: selected_body}}
    assert selected_body =~ "Selected repository"
    assert_receive {:runner_run, "repo-api", "session-3", []}
    assert_receive {:runner_waiting, "session-3", ^release_ref, runner_pid}

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "prompted",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-3",
                   "issue" => %{"id" => "issue-3"}
                 },
                 "prompt" => %{"body" => "Please also add request logging."},
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    send(runner_pid, {:release_runner, release_ref})

    assert_receive {:activity, "session-3", %{type: "thought", body: captured_body}}, 1_000
    assert captured_body =~ "Captured the follow-up prompt"
    assert_receive {:activity, "session-3", %{type: "thought", body: queued_body}}, 1_000
    assert queued_body =~ "Queued another execution cycle"
    assert_receive {:runner_run, "repo-api", "session-3", ["Please also add request logging."]}, 1_000

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "completed", repository_id: "repo-api", summary: summary}] = snapshot.runs
      assert summary =~ "Run complete for repo-api"
    end)
  end

  test "rejects a second active agent session for the same Linear issue" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-shared",
        identifier: "KEP-SHARED",
        title: "Avoid workspace collisions",
        description: "Only one active session should execute this issue",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-shared-1",
                   "issue" => %{"id" => "issue-shared"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:runner_run, "repo-api", "session-shared-1", []}
    assert_receive {:runner_waiting, "session-shared-1", ^release_ref, runner_pid}

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-shared-2",
                   "issue" => %{"id" => "issue-shared"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-shared-2", %{type: "thought", body: body}}
    assert body =~ "already has an active Kepler run"

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "prompted",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-shared-2",
                   "issue" => %{"id" => "issue-shared"}
                 },
                 "prompt" => %{"body" => "Any update?"},
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-shared-2", %{type: "thought", body: follow_up_body}}
    assert follow_up_body =~ "already has an active Kepler run"
    refute_receive {:runner_run, "repo-api", "session-shared-2", []}, 200

    snapshot = ControlPlane.snapshot()
    assert snapshot.run_count == 1
    assert [%{linear_agent_session_id: "session-shared-1", status: "executing"}] = snapshot.runs

    send(runner_pid, {:release_runner, release_ref})
  end

  test "allows a new session for the same issue after the existing run reaches a terminal state" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-terminal",
        identifier: "KEP-TERM",
        title: "Retry after completion",
        description: "A terminal run should not block a new session",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-terminal-1",
                   "issue" => %{"id" => "issue-terminal"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "completed"}] = snapshot.runs
    end)

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-terminal-2",
                   "issue" => %{"id" => "issue-terminal"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:runner_run, "repo-api", "session-terminal-2", []}
  end

  test "runs without a pull request are treated as blocked and explain the no-op outcome" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-noop",
        identifier: "KEP-NOOP",
        title: "No-op run",
        description: "Should not open a PR",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :result}, %{
      branch: "kepler/KEP-NOOP",
      codex_result: %{
        final_agent_message: "I reviewed the issue context but did not produce any code changes or open a pull request."
      },
      github_installation_id: 99,
      pr_url: nil,
      summary: "Current branch: `kepler/KEP-NOOP`.\n\nNo pull request URL was detected.\n\nWorkspace is clean after execution.",
      workspace_path: "/tmp/repo-api"
    })

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-noop",
                   "issue" => %{"id" => "issue-noop"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:issue_state_update, "issue-noop", "In Progress"}
    assert_receive {:issue_comment_create, "issue-noop", comment_id, started_comment}
    assert started_comment =~ "## Kepler Workpad"
    assert_receive {:issue_state_update, "issue-noop", "Blocked"}
    finished_comment = assert_receive_comment_update(comment_id, &String.contains?(&1, "Status: `failed`"))
    assert finished_comment =~ "## Kepler Workpad"
    assert finished_comment =~ "Status: `failed`"
    assert finished_comment =~ "Kepler requires a PR for every ticket"
    refute finished_comment =~ "#### Final model response"
    assert_receive {:activity, "session-noop", %{type: "error", body: body}}
    assert body =~ "Kepler requires a PR for every ticket"
    assert body =~ "No pull request URL was detected."
    refute_receive {:issue_state_update, "issue-noop", "In Review"}, 200
    refute_receive {:session_update, "session-noop", _input}, 200
    refute_receive {:issue_attachment, "issue-noop", _input}, 200
  end

  test "failed runs move the issue into the configured blocked state" do
    failing_runner = __MODULE__.FailingRunner

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-blocked",
        identifier: "KEP-BLOCKED",
        title: "Blocked run",
        description: "Should move to blocked",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    Application.put_env(:symphony_elixir, :kepler_execution_runner_module, failing_runner)

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-blocked",
                   "issue" => %{"id" => "issue-blocked"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:issue_state_update, "issue-blocked", "In Progress"}
    assert_receive {:issue_state_update, "issue-blocked", "Blocked"}
    assert_receive {:activity, "session-blocked", %{type: "error", body: error_body}}
    assert error_body =~ "Run failed"
  end

  test "worklog comments are not streamed on every runtime delta" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-worklog-stream",
        identifier: "KEP-STREAM",
        title: "Throttle worklog updates",
        description: "Do not stream every delta into Linear comments",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    persistent_put({FakeRunner, :events}, [
      %{event: :session_started, details: %{session_id: "fake-session"}},
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "Inspect the selected repository, make the requested code change,"}
        }
      },
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => " and open a pull request once the diff is ready."}
        }
      },
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => " This extra delta should not trigger another comment update."}
        }
      },
      %{
        event: :tool_call_completed,
        details: %{payload: %{"params" => %{"tool" => "linear_graphql"}}}
      },
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => " Final streamed text before the turn completes."}
        }
      }
    ])

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-worklog-stream",
                   "issue" => %{"id" => "issue-worklog-stream"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    refute_receive {:issue_comment_create, "issue-worklog-stream", _, _}, 200
    refute_receive {:issue_comment_update, _, _}, 200

    assert_receive {:runner_waiting, "session-worklog-stream", ^release_ref, runner_pid}
    send(runner_pid, {:release_runner, release_ref})

    assert_receive {:issue_comment_create, "issue-worklog-stream", comment_id, finished_comment}
    assert finished_comment =~ "## Kepler Workpad"
    assert finished_comment =~ "Status: `completed`"
    assert finished_comment =~ "_Kepler did not receive a persistent workpad snapshot for this run._"
    refute_receive {:issue_comment_update, ^comment_id, _body}, 200
  end

  test "workpad snapshots create once and update the same comment in place" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-workpad-sync",
        identifier: "KEP-WORKPAD",
        title: "Mirror workpad into one comment",
        description: "Workpad updates should reuse the same Linear comment",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    first_workpad =
      """
      ## Kepler Workpad

      ### Plan

      - [ ] Inspect the selected repository
      - [ ] Implement the requested code change
      """
      |> String.trim()

    second_workpad =
      """
      ## Kepler Workpad

      ### Plan

      - [x] Inspect the selected repository
      - [ ] Implement the requested code change
      - [ ] Run targeted validation
      """
      |> String.trim()

    persistent_put({FakeRunner, :events}, [
      %{event: :session_started, details: %{session_id: "fake-session"}},
      %{event: :workpad_snapshot, details: %{hash: "hash-1", markdown: first_workpad}},
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "Planning the implementation before editing any files."}
        }
      },
      %{event: :workpad_snapshot, details: %{hash: "hash-2", markdown: second_workpad}},
      %{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => "Streaming text alone should not create another comment."}
        }
      }
    ])

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-workpad-sync",
                   "issue" => %{"id" => "issue-workpad-sync"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:issue_comment_create, "issue-workpad-sync", comment_id, started_comment}
    assert started_comment =~ "Status: `executing`"
    assert started_comment =~ "## Kepler Workpad"
    refute started_comment =~ "## Kepler Workpad\n\n---\n\n## Kepler Workpad"
    assert started_comment =~ "- [ ] Inspect the selected repository"
    refute started_comment =~ "- [x] Inspect the selected repository"

    updated_comment =
      assert_receive_comment_update(
        comment_id,
        &String.contains?(&1, "- [x] Inspect the selected repository")
      )

    assert updated_comment =~ "- [ ] Run targeted validation"
    refute_receive {:issue_comment_create, "issue-workpad-sync", _, _}, 200
    refute_receive {:issue_comment_update, ^comment_id, _body}, 200

    assert_receive {:runner_waiting, "session-workpad-sync", ^release_ref, runner_pid}
    send(runner_pid, {:release_runner, release_ref})

    finished_comment =
      assert_receive_comment_update(comment_id, &String.contains?(&1, "Status: `completed`"))

    assert finished_comment =~ "- [x] Inspect the selected repository"
    assert finished_comment =~ "- [ ] Run targeted validation"
  end

  test "reuses the latest worklog comment for reruns on the same issue" do
    existing_run =
      Run.new(%{
        id: "run-existing-worklog",
        linear_issue_id: "issue-worklog-reuse",
        linear_issue_identifier: "KEP-REUSE",
        linear_issue_title: "Reuse worklog comment",
        linear_issue_url: "https://linear.app/example/issue/KEP-REUSE",
        linear_agent_session_id: "session-existing-worklog",
        repository_id: "repo-api",
        status: "completed",
        branch: "kepler/KEP-REUSE",
        pr_url: "https://github.com/example/repo-api/pull/7",
        worklog_comment_id: "comment-existing-worklog"
      })

    :sys.replace_state(ControlPlane, fn state ->
      %{
        state
        | runs: %{existing_run.id => existing_run},
          queued_run_ids: [],
          active_run_ids: [],
          task_refs: %{}
      }
    end)

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-worklog-reuse",
        identifier: "KEP-REUSE",
        title: "Reuse worklog comment",
        description: "Reruns should update the same comment instead of creating a new one",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-worklog-reuse",
                   "issue" => %{"id" => "issue-worklog-reuse"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    started_comment =
      assert_receive_comment_update(
        "comment-existing-worklog",
        &String.contains?(&1, "Status: `executing`")
      )

    assert started_comment =~ "## Kepler Workpad"
    refute started_comment =~ "## Kepler Workpad\n\n---\n\n## Kepler Workpad"
    refute_receive {:issue_comment_create, "issue-worklog-reuse", _, _}, 200

    finished_comment =
      assert_receive_comment_update(
        "comment-existing-worklog",
        &String.contains?(&1, "Status: `completed`")
      )

    assert finished_comment =~ "Pull request: attached to the issue"
  end

  test "no-pr runs that explicitly ask for more input are classified separately" do
    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-needs-input",
        identifier: "KEP-INPUT",
        title: "Need more input",
        description: "Should ask for clarification instead of silently succeeding",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :result}, %{
      branch: "kepler/KEP-INPUT",
      codex_result: %{
        final_agent_message: "I need more information about the expected frontend behavior before I can implement this change and open a pull request."
      },
      github_installation_id: 99,
      pr_url: nil,
      summary: "Current branch: `kepler/KEP-INPUT`.\n\nNo pull request URL was detected.\n\nWorkspace is clean after execution.",
      workspace_path: "/tmp/repo-api"
    })

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-needs-input",
                   "issue" => %{"id" => "issue-needs-input"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:issue_state_update, "issue-needs-input", "In Progress"}
    assert_receive {:issue_state_update, "issue-needs-input", "Blocked"}
    assert_receive {:activity, "session-needs-input", %{type: "response", body: body}}
    assert body =~ "need more information"

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "needs_input"}] = Enum.filter(snapshot.runs, &(&1.linear_issue_id == "issue-needs-input"))
    end)
  end

  test "rejected second sessions get the existing PR backlink when the active run already has one" do
    existing_run_id = "run-existing-pr"

    existing_run =
      Run.new(%{
        id: existing_run_id,
        linear_issue_id: "issue-existing-pr",
        linear_issue_identifier: "KEP-LINK",
        linear_issue_title: "Use the active PR",
        linear_issue_url: "https://linear.app/example/issue/KEP-LINK",
        linear_agent_session_id: "session-existing-pr-1",
        repository_id: "repo-api",
        status: "executing",
        pr_url: "https://github.com/example/repo-api/pull/42"
      })

    :sys.replace_state(ControlPlane, fn state ->
      %{
        state
        | runs: %{existing_run_id => existing_run},
          queued_run_ids: [],
          active_run_ids: [existing_run_id],
          task_refs: %{}
      }
    end)

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-existing-pr",
        identifier: "KEP-LINK",
        title: "Use the active PR",
        description: "Second sessions should get the existing backlink",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-existing-pr-2",
                   "issue" => %{"id" => "issue-existing-pr"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:activity, "session-existing-pr-2", %{type: "thought", body: body}}
    assert body =~ "already has an active Kepler run"

    assert_receive {:session_update, "session-existing-pr-2", %{externalUrls: [%{label: "Existing Pull Request", url: "https://github.com/example/repo-api/pull/42"}]}}
  end

  test "does not oversubscribe queued runs while all concurrency slots are occupied" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-oversubscribe",
        identifier: "KEP-SAT",
        title: "Respect concurrency limits",
        description: "Only one run should execute at a time",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-saturated-1",
                   "issue" => %{"id" => "issue-saturated-1"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:runner_run, "repo-api", "session-saturated-1", []}
    assert_receive {:runner_waiting, "session-saturated-1", ^release_ref, runner_pid}

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-saturated-2",
                   "issue" => %{"id" => "issue-saturated-2"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert :ok = ControlPlane.request_refresh()
    refute_receive {:runner_run, "repo-api", "session-saturated-2", []}, 200

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      assert snapshot.active_count == 1
      assert snapshot.queued_count == 1

      assert Enum.any?(snapshot.runs, &(&1.linear_agent_session_id == "session-saturated-1" and &1.status == "executing"))
      assert Enum.any?(snapshot.runs, &(&1.linear_agent_session_id == "session-saturated-2" and &1.status == "queued"))
    end)

    send(runner_pid, {:release_runner, release_ref})

    assert_receive {:runner_run, "repo-api", "session-saturated-2", []}, 1_000
  end

  test "returns unavailable and does not acknowledge intake when persistence fails" do
    Application.put_env(:symphony_elixir, :kepler_state_store_module, FailingStateStore)

    assert {:error, :unavailable} =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-persist-failure",
                   "issue" => %{"id" => "issue-persist-failure"},
                   "promptContext" => "Do not acknowledge a non-durable intake."
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    refute_receive {:activity, "session-persist-failure", _}, 200
    refute_receive {:runner_run, _, "session-persist-failure", _}, 200

    snapshot = ControlPlane.snapshot()
    assert snapshot.run_count == 0
    assert snapshot.queued_count == 0
    assert snapshot.active_count == 0
  end

  test "restart recovery requeues interrupted runs without leaving stale active capacity" do
    release_ref = make_ref()

    persistent_put(
      {FakeLinearClient, :issue},
      %SymphonyElixir.Kepler.Linear.IssueContext{
        id: "issue-4",
        identifier: "KEP-99",
        title: "Recover after restart",
        description: "Hosted recovery",
        labels: ["api"],
        team_key: "ENG",
        project_slug: "kepler"
      }
    )

    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})

    assert :ok =
             ControlPlane.handle_webhook(%{
               "action" => "created",
               "data" => %{
                 "agentSession" => %{
                   "id" => "session-4",
                   "issue" => %{"id" => "issue-4"}
                 },
                 "webhookTimestamp" => System.system_time(:millisecond)
               }
             })

    assert_receive {:runner_run, "repo-api", "session-4", []}
    assert_receive {:runner_waiting, "session-4", ^release_ref, _runner_pid}

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "executing", repository_id: "repo-api"}] = snapshot.runs
      assert snapshot.active_count == 1
    end)

    stop_supervised!(ControlPlane)
    persistent_put({FakeRunner, :release}, :immediate)
    start_supervised!(ControlPlane)

    assert_receive {:runner_run, "repo-api", "session-4", []}, 1_000

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      [%{status: "completed", repository_id: "repo-api", summary: summary}] = snapshot.runs
      assert summary =~ "Run complete for repo-api"
      assert snapshot.active_count == 0
      assert snapshot.queued_count == 0
    end)
  end

  test "prunes retained terminal history while keeping non-terminal runs", %{config_path: config_path} do
    Application.put_env(:symphony_elixir, :kepler_retained_terminal_runs, 2)
    release_ref = make_ref()

    settings = Config.settings!()
    state_file_path = Path.join(settings.state.root, settings.state.file_name)
    stop_supervised!(ControlPlane)

    File.mkdir_p!(Path.dirname(state_file_path))

    payload = %{
      "runs" => [
        terminal_run("run-completed-oldest", "completed", "2026-01-01T00:00:00Z"),
        terminal_run("run-completed-middle", "completed", "2026-01-02T00:00:00Z"),
        terminal_run("run-failed-newest", "failed", "2026-01-03T00:00:00Z"),
        queued_run("run-queued", "2026-01-04T00:00:00Z")
      ],
      "queued_run_ids" => ["run-queued"],
      "active_run_ids" => []
    }

    File.write!(state_file_path, Jason.encode!(payload))

    Config.set_config_file_path(config_path)
    persistent_put({FakeRunner, :release}, {:block_once, self(), release_ref})
    start_supervised!(ControlPlane)

    assert_eventually(fn ->
      snapshot = ControlPlane.snapshot()
      retained_ids = Enum.map(snapshot.runs, & &1.id)

      assert snapshot.run_count == 3
      assert "run-completed-oldest" not in retained_ids
      assert "run-completed-middle" in retained_ids
      assert "run-failed-newest" in retained_ids
      assert "run-queued" in retained_ids
      assert Enum.any?(snapshot.runs, &(&1.id == "run-queued" and &1.status in ["queued", "executing"]))
    end)

    persisted_payload =
      state_file_path
      |> File.read!()
      |> Jason.decode!()

    persisted_ids = Enum.map(persisted_payload["runs"], & &1["id"])
    queued_run = Enum.find(persisted_payload["runs"], &(&1["id"] == "run-queued"))

    assert length(persisted_ids) == 3
    assert "run-completed-oldest" not in persisted_ids
    assert queued_run["status"] in ["queued", "executing"]

    assert MapSet.new(persisted_payload["queued_run_ids"] ++ persisted_payload["active_run_ids"]) ==
             MapSet.new(["run-queued"])

    assert_receive {:runner_waiting, "run-queued-session", ^release_ref, runner_pid}
    send(runner_pid, {:release_runner, release_ref})
  end

  defp write_kepler_config!(config_path, config_root) do
    File.write!(
      config_path,
      """
      service_name: "Kepler"
      server:
        host: "127.0.0.1"
        port: 4040
      linear:
        api_key: "linear-token"
        webhook_secret: "linear-secret"
        executing_state_name: "In Progress"
        review_state_name: "In Review"
        blocked_state_name: "Blocked"
      github:
        bot_name: "Kepler Bot"
        bot_email: "kepler@example.com"
      workspace:
        root: "#{Path.join(config_root, "workspaces")}"
      state:
        root: "#{Path.join(config_root, "state")}"
      limits:
        max_concurrent_runs: 1
        dispatch_interval_ms: 50
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "#{config_root}"
          labels: ["api"]
        - id: "repo-web"
          full_name: "example/repo-web"
          clone_url: "#{config_root}"
          team_keys: ["WEB"]
      """
    )
  end

  defmodule FailingRunner do
    alias SymphonyElixir.Kepler.Run

    @spec run(Run.t(), keyword()) :: {:error, atom()}
    def run(_run, _opts \\ []), do: {:error, :blocked_for_test}
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(50)

      if attempts > 0 do
        assert_eventually(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp assert_receive_comment_update(comment_id, matcher, attempts \\ 5)

  defp assert_receive_comment_update(_comment_id, _matcher, 0) do
    flunk("did not receive a matching issue comment update")
  end

  defp assert_receive_comment_update(comment_id, matcher, attempts) do
    receive do
      {:issue_comment_update, ^comment_id, body} ->
        if matcher.(body) do
          body
        else
          assert_receive_comment_update(comment_id, matcher, attempts - 1)
        end
    after
      1_000 ->
        flunk("did not receive issue comment update for #{inspect(comment_id)}")
    end
  end

  defp persistent_get(key), do: :persistent_term.get(key, :__missing__)

  defp persistent_put(key, value) do
    :persistent_term.put(key, value)
  end

  defp persistent_restore(key, :__missing__) do
    :persistent_term.erase(key)
  end

  defp persistent_restore(key, value) do
    :persistent_term.put(key, value)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp terminal_run(id, status, timestamp) do
    %{
      "id" => id,
      "linear_issue_id" => "#{id}-issue",
      "linear_issue_identifier" => String.upcase(id),
      "linear_agent_session_id" => "#{id}-session",
      "repository_id" => "repo-api",
      "provider" => "codex",
      "status" => status,
      "follow_up_prompts" => [],
      "active_follow_up_prompts" => [],
      "issue_labels" => ["api"],
      "created_at" => timestamp,
      "updated_at" => timestamp
    }
  end

  defp queued_run(id, timestamp) do
    %{
      "id" => id,
      "linear_issue_id" => "#{id}-issue",
      "linear_issue_identifier" => String.upcase(id),
      "linear_agent_session_id" => "#{id}-session",
      "repository_id" => "repo-api",
      "provider" => "codex",
      "status" => "queued",
      "follow_up_prompts" => [],
      "active_follow_up_prompts" => [],
      "issue_labels" => ["api"],
      "created_at" => timestamp,
      "updated_at" => timestamp
    }
  end
end
