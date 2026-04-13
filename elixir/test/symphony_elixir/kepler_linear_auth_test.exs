defmodule SymphonyElixir.KeplerLinearAuthTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Linear.Auth
  alias SymphonyElixir.Kepler.Linear.Client

  defmodule FakeReq do
    def post(url, opts) do
      handler = :persistent_term.get({__MODULE__, :handler})
      handler.(url, opts)
    end
  end

  setup do
    config_root =
      Path.join(
        System.tmp_dir!(),
        "kepler-linear-auth-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(config_root)

    config_path = Path.join(config_root, "kepler.yml")

    write_config!(config_path, :client_credentials)

    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_http_client = Application.get_env(:symphony_elixir, :kepler_linear_http_client_module)
    original_github_token = System.get_env("GITHUB_TOKEN")
    original_handler = persistent_get({FakeReq, :handler})

    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    Config.set_config_file_path(config_path)
    Application.put_env(:symphony_elixir, :kepler_linear_http_client_module, FakeReq)
    start_supervised!(SymphonyElixir.Kepler.Supervisor)

    on_exit(fn ->
      if is_nil(original_config_path),
        do: Config.clear_config_file_path(),
        else: Config.set_config_file_path(original_config_path)

      restore_app_env(:kepler_linear_http_client_module, original_http_client)
      restore_env("GITHUB_TOKEN", original_github_token)
      persistent_restore({FakeReq, :handler}, original_handler)
      File.rm_rf(config_root)
    end)

    %{config_path: config_path}
  end

  test "client credentials headers are fetched once and then cached" do
    response_agent =
      start_supervised!({Agent, fn -> [{:ok, %{status: 200, body: token_body("token-1")}}] end})

    install_fake_req_handler(response_agent)

    assert {:ok, headers_one} = Auth.headers()
    assert {:ok, headers_two} = Auth.headers()

    assert authorization_header(headers_one) == "Bearer token-1"
    assert authorization_header(headers_two) == "Bearer token-1"

    assert_receive {:fake_req, "https://api.linear.app/oauth/token", opts}
    assert opts[:body] =~ "grant_type=client_credentials"
    assert opts[:body] =~ "scope=read%2Cwrite%2Capp%3Aassignable%2Capp%3Amentionable"
    refute_receive {:fake_req, _, _}, 200
  end

  test "Kepler supervisor owns and restarts Linear auth" do
    supervisor = Process.whereis(SymphonyElixir.Kepler.Supervisor)
    assert is_pid(supervisor)

    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 200, body: token_body("token-1")}},
             {:ok, %{status: 200, body: token_body("token-2")}},
             {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app-user"}}}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:ok, headers} = Auth.headers()
    assert authorization_header(headers) == "Bearer token-1"

    auth_pid = Process.whereis(Auth)
    assert is_pid(auth_pid)
    Process.exit(auth_pid, :kill)

    restarted_pid =
      assert_eventually(fn ->
        new_pid = Process.whereis(Auth)
        assert is_pid(new_pid)
        assert new_pid != auth_pid
        new_pid
      end)

    assert Process.alive?(supervisor)
    assert Process.alive?(restarted_pid)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "app-user"}}}} =
             Client.graphql("query Viewer { viewer { id } }")

    assert_receive {:fake_req, "https://api.linear.app/oauth/token", _}
    assert_receive {:fake_req, "https://api.linear.app/oauth/token", _}
    assert_receive {:fake_req, "https://api.linear.app/graphql", _}
  end

  test "graphql retries once with a fresh client credentials token after a 401" do
    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 200, body: token_body("token-1")}},
             {:ok, %{status: 401, body: %{"error" => "expired"}}},
             {:ok, %{status: 200, body: token_body("token-2")}},
             {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app-user"}}}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "app-user"}}}} =
             Client.graphql("query Viewer { viewer { id } }")

    assert_receive {:fake_req, "https://api.linear.app/oauth/token", token_opts_one}
    assert_receive {:fake_req, "https://api.linear.app/graphql", graphql_opts_one}
    assert_receive {:fake_req, "https://api.linear.app/oauth/token", token_opts_two}
    assert_receive {:fake_req, "https://api.linear.app/graphql", graphql_opts_two}

    assert authorization_header(token_opts_one[:headers]) =~ "Basic "
    assert authorization_header(graphql_opts_one[:headers]) == "Bearer token-1"
    assert authorization_header(token_opts_two[:headers]) =~ "Basic "
    assert authorization_header(graphql_opts_two[:headers]) == "Bearer token-2"
  end

  test "graphql surfaces GraphQL errors returned in a 200 response" do
    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 200, body: token_body("token-1")}},
             {:ok, %{status: 200, body: %{"errors" => [%{"message" => "forbidden"}]}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:error, {:linear_graphql_errors, ["forbidden"]}} =
             Client.graphql("query Viewer { viewer { id } }")
  end

  test "headers surface malformed client credentials responses cleanly" do
    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 200, body: %{"token_type" => "Bearer"}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:error, :invalid_linear_oauth_response} = Auth.headers()
  end

  test "graphql does not retry 401 responses in api key mode", %{config_path: config_path} do
    write_config!(config_path, :api_key)
    Config.set_config_file_path(config_path)

    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 401, body: %{"error" => "nope"}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:error, {:linear_api_status, 401}} =
             Client.graphql("query Viewer { viewer { id } }")

    assert_receive {:fake_req, "https://api.linear.app/graphql", graphql_opts}
    assert authorization_header(graphql_opts[:headers]) == "lin_api_test"
    refute_receive {:fake_req, "https://api.linear.app/oauth/token", _}
    refute_receive {:fake_req, "https://api.linear.app/graphql", _}, 200
  end

  test "graphql surfaces non-401 HTTP status responses", %{config_path: config_path} do
    write_config!(config_path, :api_key)
    Config.set_config_file_path(config_path)

    response_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{status: 500, body: %{"error" => "boom"}}}
           ]
         end}
      )

    install_fake_req_handler(response_agent)

    assert {:error, {:linear_api_status, 500}} =
             Client.graphql("query Viewer { viewer { id } }")
  end

  defp install_fake_req_handler(response_agent) do
    recipient = self()

    persistent_put(
      {FakeReq, :handler},
      fn url, opts ->
        send(recipient, {:fake_req, url, opts})

        Agent.get_and_update(response_agent, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, :unexpected_request}, []}
        end)
      end
    )
  end

  defp token_body(access_token) do
    %{
      "access_token" => access_token,
      "token_type" => "Bearer",
      "expires_in" => 2_592_000,
      "scope" => "read write app:assignable app:mentionable"
    }
  end

  defp write_config!(config_path, :client_credentials) do
    File.write!(
      config_path,
      """
      service_name: "Kepler"
      linear:
        client_id: "linear-client-id"
        client_secret: "linear-client-secret"
        webhook_secret: "linear-secret"
      github:
        bot_name: "Kepler Bot"
        bot_email: "kepler@example.com"
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "https://github.com/example/repo-api.git"
      """
    )
  end

  defp write_config!(config_path, :api_key) do
    File.write!(
      config_path,
      """
      service_name: "Kepler"
      linear:
        api_key: "lin_api_test"
        webhook_secret: "linear-secret"
      github:
        bot_name: "Kepler Bot"
        bot_email: "kepler@example.com"
      repositories:
        - id: "repo-api"
          full_name: "example/repo-api"
          clone_url: "https://github.com/example/repo-api.git"
      """
    )
  end

  defp authorization_header(headers) do
    headers
    |> Enum.find_value(fn
      {"Authorization", value} -> value
      {"authorization", value} -> value
      _ -> nil
    end)
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

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
      end
  end
end
