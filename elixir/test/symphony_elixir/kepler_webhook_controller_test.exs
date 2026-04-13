defmodule SymphonyElixir.KeplerWebhookControllerTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Plug.Conn

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.ControlPlane
  alias SymphonyElixir.Kepler.StateStore
  alias SymphonyElixir.RuntimeMode

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    alias SymphonyElixir.Kepler.Linear.IssueContext

    @spec fetch_issue(String.t()) :: {:ok, IssueContext.t()}
    def fetch_issue(issue_id) do
      {:ok,
       %IssueContext{
         id: issue_id,
         identifier: "KEP-HTTP",
         title: "Webhook intake",
         description: "Controller test",
         labels: ["api"],
         team_key: "ENG",
         project_slug: "kepler"
       }}
    end

    @spec suggest_repositories(String.t(), String.t(), [map()]) :: {:ok, [map()]}
    def suggest_repositories(_issue_id, _agent_session_id, _candidate_repositories), do: {:ok, []}

    @spec create_agent_activity(String.t(), map(), keyword()) :: :ok
    def create_agent_activity(_agent_session_id, _content, _opts \\ []), do: :ok

    @spec update_agent_session(String.t(), map()) :: :ok
    def update_agent_session(_agent_session_id, _input), do: :ok

    @spec create_issue_attachment(String.t(), map()) :: :ok
    def create_issue_attachment(_issue_id, _input), do: :ok

    @spec graphql(String.t(), map(), keyword()) :: {:ok, map()}
    def graphql(_query, _variables, _opts \\ []), do: {:ok, %{}}
  end

  defmodule FakeRunner do
    alias SymphonyElixir.Kepler.Run

    @spec run(Run.t(), keyword()) :: {:ok, map()}
    def run(run, _opts \\ []) do
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
        "kepler-webhook-controller-test-#{System.unique_integer([:positive])}"
      )

    config_path = Path.join(config_root, "kepler.yml")
    File.mkdir_p!(config_root)

    File.write!(
      config_path,
      """
      service_name: "Kepler"
      server:
        host: "127.0.0.1"
        port: 4040
        api_token: "ops-token"
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
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "#{config_root}"
          labels: ["api"]
      """
    )

    original_runtime_mode = Application.get_env(:symphony_elixir, :runtime_mode)
    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_linear_client = Application.get_env(:symphony_elixir, :kepler_linear_client_module)
    original_runner = Application.get_env(:symphony_elixir, :kepler_execution_runner_module)
    original_state_store = Application.get_env(:symphony_elixir, :kepler_state_store_module)
    original_github_token = System.get_env("GITHUB_TOKEN")

    RuntimeMode.set(:kepler)
    Config.set_config_file_path(config_path)
    Application.put_env(:symphony_elixir, :kepler_linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :kepler_execution_runner_module, FakeRunner)
    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    start_supervised!(SymphonyElixirWeb.Endpoint)

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

      restore_env("GITHUB_TOKEN", original_github_token)
      File.rm_rf(config_root)
    end)

    %{config_path: config_path, config_root: config_root}
  end

  test "returns 200 only after the webhook is synchronously accepted" do
    start_supervised!(ControlPlane)

    payload = %{
      "action" => "created",
      "data" => %{
        "agentSession" => %{
          "id" => "session-http-1",
          "issue" => %{"id" => "issue-http-1"},
          "promptContext" => "Review webhook intake."
        },
        "webhookTimestamp" => System.system_time(:millisecond)
      }
    }

    conn = post_signed_webhook(payload)

    assert response(conn, 200) == ""

    snapshot = ControlPlane.snapshot()
    assert snapshot.run_count == 1
    assert [%{linear_agent_session_id: "session-http-1"}] = snapshot.runs
  end

  test "returns 503 when the control plane is unavailable" do
    payload = %{
      "action" => "created",
      "data" => %{
        "agentSession" => %{
          "id" => "session-http-2",
          "issue" => %{"id" => "issue-http-2"}
        },
        "webhookTimestamp" => System.system_time(:millisecond)
      }
    }

    conn = post_signed_webhook(payload)

    assert response(conn, 503) == ""
  end

  test "rejects webhooks with an invalid signature" do
    payload = %{
      "action" => "created",
      "data" => %{
        "agentSession" => %{
          "id" => "session-http-bad-signature",
          "issue" => %{"id" => "issue-http-bad-signature"}
        },
        "webhookTimestamp" => System.system_time(:millisecond)
      }
    }

    conn = post_signed_webhook(payload, signature: "deadbeef")

    assert response(conn, 401) == ""
  end

  test "rejects webhooks with a stale timestamp even when the signature matches" do
    payload = %{
      "action" => "created",
      "data" => %{
        "agentSession" => %{
          "id" => "session-http-stale",
          "issue" => %{"id" => "issue-http-stale"}
        },
        "webhookTimestamp" => System.system_time(:millisecond) - 120_000
      }
    }

    conn = post_signed_webhook(payload)

    assert response(conn, 401) == ""
  end

  test "returns 503 when durable intake persistence fails" do
    Application.put_env(:symphony_elixir, :kepler_state_store_module, FailingStateStore)
    start_supervised!(ControlPlane)

    payload = %{
      "action" => "created",
      "data" => %{
        "agentSession" => %{
          "id" => "session-http-persist-failure",
          "issue" => %{"id" => "issue-http-persist-failure"},
          "promptContext" => "Only acknowledge durable work."
        },
        "webhookTimestamp" => System.system_time(:millisecond)
      }
    }

    conn = post_signed_webhook(payload)

    assert response(conn, 503) == ""

    snapshot = ControlPlane.snapshot()
    assert snapshot.run_count == 0
    assert snapshot.queued_count == 0
    assert snapshot.active_count == 0
  end

  test "health reports ready only when the control plane is running" do
    conn = build_conn() |> get("/api/v1/kepler/health")
    assert %{"mode" => "kepler", "ok" => false} = json_response(conn, 503)

    start_supervised!(ControlPlane)

    conn = build_conn() |> get("/api/v1/kepler/health")

    assert %{"mode" => "kepler", "ok" => true} = json_response(conn, 200)
  end

  test "runs endpoint requires the configured API token" do
    start_supervised!(ControlPlane)

    unauthorized_conn = build_conn() |> get("/api/v1/kepler/runs")
    assert response(unauthorized_conn, 401) == ""

    authorized_conn =
      build_conn()
      |> put_req_header("x-kepler-api-token", "ops-token")
      |> get("/api/v1/kepler/runs")

    assert %{"mode" => "kepler", "run_count" => _, "runs" => _runs} = json_response(authorized_conn, 200)
  end

  test "runs endpoint accepts Bearer auth when the configured token matches" do
    start_supervised!(ControlPlane)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer ops-token")
      |> get("/api/v1/kepler/runs")

    assert %{"mode" => "kepler", "run_count" => _, "runs" => _runs} = json_response(conn, 200)
  end

  test "runs endpoint stays disabled when server.api_token is not configured", %{config_root: config_root} do
    config_path = Path.join(config_root, "kepler-no-api-token.yml")

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
        root: "#{Path.join(config_root, "workspaces-no-token")}"
      state:
        root: "#{Path.join(config_root, "state-no-token")}"
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "#{config_root}"
          labels: ["api"]
      """
    )

    Config.set_config_file_path(config_path)
    conn = build_conn() |> get("/api/v1/kepler/runs")
    assert response(conn, 404) == ""
  end

  test "oauth callback endpoint returns an operator-facing confirmation" do
    conn = build_conn() |> get("/linear/oauth/callback")

    assert response(conn, 200) =~ "Kepler received the Linear OAuth redirect"
  end

  defp post_signed_webhook(payload, opts \\ []) do
    body = Jason.encode!(payload)

    signature =
      Keyword.get_lazy(opts, :signature, fn ->
        :crypto.mac(:hmac, :sha256, Config.settings!().linear.webhook_secret, body)
        |> Base.encode16(case: :lower)
      end)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("linear-signature", signature)
    |> post("/webhooks/linear", body)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
