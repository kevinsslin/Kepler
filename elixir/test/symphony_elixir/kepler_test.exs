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

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()}
    def graphql(_query, _variables, _opts \\ []), do: {:ok, %{}}
  end

  defmodule FakeRunner do
    alias SymphonyElixir.Kepler.Run

    @spec run(Run.t(), keyword()) :: {:ok, map()}
    def run(run, _opts \\ []) do
      if recipient = :persistent_term.get({__MODULE__, :recipient}, nil) do
        send(
          recipient,
          {:runner_run, run.repository_id, run.linear_agent_session_id, run.active_follow_up_prompts}
        )
      end

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

      {:ok,
       %{
         branch: "kepler/#{run.linear_issue_identifier}",
         github_installation_id: 99,
         pr_url: "https://github.com/example/#{run.repository_id}/pull/1",
         summary: "Run complete for #{run.repository_id}",
         workspace_path: "/tmp/#{run.repository_id}"
       }}
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
    original_github_token = System.get_env("GITHUB_TOKEN")

    RuntimeMode.set(:kepler)
    Config.set_config_file_path(config_path)
    Application.put_env(:symphony_elixir, :kepler_linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :kepler_execution_runner_module, FakeRunner)
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    persistent_put({FakeLinearClient, :recipient}, self())
    persistent_put({FakeRunner, :recipient}, self())
    persistent_put({FakeRunner, :release}, :immediate)
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

    assert_receive {:activity, "session-1", %{type: "thought", body: body}}
    assert body =~ "Acknowledged"
    assert_receive {:runner_run, "repo-api", "session-1", []}
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
