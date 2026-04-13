defmodule SymphonyElixir.KeplerConfigTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Config.Schema

  setup do
    original_config_path = Application.get_env(:symphony_elixir, :kepler_config_file_path)
    original_github_token = System.get_env("GITHUB_TOKEN")
    original_linear_api_key = System.get_env("LINEAR_API_KEY")
    original_linear_webhook_secret = System.get_env("LINEAR_WEBHOOK_SECRET")
    original_linear_client_id = System.get_env("LINEAR_CLIENT_ID")
    original_linear_client_secret = System.get_env("LINEAR_CLIENT_SECRET")
    original_workspace_root = System.get_env("KEPLER_WORKSPACE_ROOT")
    original_state_root = System.get_env("KEPLER_STATE_ROOT")
    original_fallback_path = System.get_env("KEPLER_FALLBACK_WORKFLOW_PATH")
    original_api_token = System.get_env("KEPLER_API_TOKEN")
    original_github_app_id = System.get_env("GITHUB_APP_ID")
    original_github_private_key = System.get_env("GITHUB_APP_PRIVATE_KEY")

    on_exit(fn ->
      if is_nil(original_config_path),
        do: Config.clear_config_file_path(),
        else: Config.set_config_file_path(original_config_path)

      restore_env("GITHUB_TOKEN", original_github_token)
      restore_env("LINEAR_API_KEY", original_linear_api_key)
      restore_env("LINEAR_WEBHOOK_SECRET", original_linear_webhook_secret)
      restore_env("LINEAR_CLIENT_ID", original_linear_client_id)
      restore_env("LINEAR_CLIENT_SECRET", original_linear_client_secret)
      restore_env("KEPLER_WORKSPACE_ROOT", original_workspace_root)
      restore_env("KEPLER_STATE_ROOT", original_state_root)
      restore_env("KEPLER_FALLBACK_WORKFLOW_PATH", original_fallback_path)
      restore_env("KEPLER_API_TOKEN", original_api_token)
      restore_env("GITHUB_APP_ID", original_github_app_id)
      restore_env("GITHUB_APP_PRIVATE_KEY", original_github_private_key)
    end)

    :ok
  end

  test "rejects custom webhook paths because the route is fixed in v1" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    assert {:error, {:invalid_kepler_config, message}} =
             Config.load_from_string(base_config(webhook_path: "/webhooks/custom"))

    assert message =~ "linear.webhook_path is fixed at /webhooks/linear"
  end

  test "accepts Linear client credentials without a personal API key" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    assert {:ok, settings} =
             Config.load_from_string(
               base_config(
                 api_key: "null",
                 client_id: "\"linear-client-id\"",
                 client_secret: "\"linear-client-secret\""
               )
             )

    assert settings.linear.api_key == nil
    assert settings.linear.client_id == "linear-client-id"
    assert settings.linear.client_secret == "linear-client-secret"
    assert Schema.linear_auth_mode(settings.linear) == :client_credentials
  end

  test "resolves Linear client credentials from environment variables" do
    client_id_env = "KEPLER_LINEAR_CLIENT_ID_#{System.unique_integer([:positive])}"
    client_secret_env = "KEPLER_LINEAR_CLIENT_SECRET_#{System.unique_integer([:positive])}"
    previous_client_id = System.get_env(client_id_env)
    previous_client_secret = System.get_env(client_secret_env)

    on_exit(fn ->
      restore_env(client_id_env, previous_client_id)
      restore_env(client_secret_env, previous_client_secret)
    end)

    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    System.put_env(client_id_env, "linear-client-id-from-env")
    System.put_env(client_secret_env, "linear-client-secret-from-env")

    assert {:ok, settings} =
             Config.load_from_string(
               base_config(
                 api_key: "null",
                 client_id: "$#{client_id_env}",
                 client_secret: "$#{client_secret_env}"
               )
             )

    assert settings.linear.client_id == "linear-client-id-from-env"
    assert settings.linear.client_secret == "linear-client-secret-from-env"
    assert Schema.linear_auth_mode(settings.linear) == :client_credentials
  end

  test "fails fast when env-backed Linear client secrets do not resolve" do
    missing_var = "KEPLER_MISSING_LINEAR_CLIENT_SECRET_#{System.unique_integer([:positive])}"
    System.delete_env(missing_var)
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    assert {:error, {:invalid_kepler_config, message}} =
             Config.load_from_string(
               base_config(
                 api_key: "null",
                 client_id: "\"linear-client-id\"",
                 client_secret: "$#{missing_var}"
               )
             )

    assert message =~ "linear.client_secret must resolve to a non-empty value at boot time"
  end

  test "fails fast when no Linear runtime auth is available" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    assert {:error, {:invalid_kepler_config, message}} =
             Config.load_from_string(
               base_config(
                 api_key: "null",
                 client_id: "null",
                 client_secret: "null"
               )
             )

    assert message =~
             "either linear.client_id + linear.client_secret or linear.api_key must resolve to non-empty values at boot time"
  end

  test "fails fast when no GitHub auth is available" do
    System.delete_env("GITHUB_TOKEN")

    assert {:error, {:invalid_kepler_config, message}} = Config.load_from_string(base_config())

    assert message =~ "github auth is required"
  end

  test "settings are cached for the configured path until the path changes" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    root = Path.join(System.tmp_dir!(), "kepler-config-test-#{System.unique_integer([:positive])}")
    path_one = Path.join(root, "one.yml")
    path_two = Path.join(root, "two.yml")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    File.write!(path_one, base_config(api_key: "linear-token-one"))
    File.write!(path_two, base_config(api_key: "linear-token-two"))

    Config.set_config_file_path(path_one)
    assert Config.settings!().linear.api_key == "linear-token-one"

    File.write!(path_one, base_config(api_key: "linear-token-overwritten"))
    assert Config.settings!().linear.api_key == "linear-token-one"

    Config.set_config_file_path(path_two)
    assert Config.settings!().linear.api_key == "linear-token-two"
  end

  test "accepts explicit routing.fallback_workflow_path override" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    explicit_path = Path.expand("tmp/custom/WORKFLOW.md")

    assert {:ok, settings} =
             Config.load_from_string(base_config(fallback_workflow_path: "tmp/custom/WORKFLOW.md"))

    assert settings.routing.fallback_workflow_path == explicit_path
  end

  test "resolves server.api_token from the environment" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    System.put_env("KEPLER_API_TOKEN", "ops-token-from-env")

    assert {:ok, settings} = Config.load_from_string(base_config(server_api_token: "$KEPLER_API_TOKEN"))

    assert settings.server.api_token == "ops-token-from-env"
  end

  test "accepts env-backed routing.fallback_workflow_path override" do
    env_name = "KEPLER_FALLBACK_PATH_#{System.unique_integer([:positive])}"
    previous_value = System.get_env(env_name)
    fallback_path = Path.join(System.tmp_dir!(), "fallback-#{System.unique_integer([:positive])}.md")

    on_exit(fn -> restore_env(env_name, previous_value) end)

    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    System.put_env(env_name, fallback_path)

    assert {:ok, settings} =
             Config.load_from_string(base_config(fallback_workflow_path: "$#{env_name}"))

    assert settings.routing.fallback_workflow_path == Path.expand(fallback_path)
  end

  test "missing env-backed fallback path uses the bundled default" do
    env_name = "KEPLER_MISSING_FALLBACK_PATH_#{System.unique_integer([:positive])}"
    System.delete_env(env_name)
    System.put_env("GITHUB_TOKEN", "kepler-test-token")

    assert {:ok, default_settings} = Config.load_from_string(base_config())

    assert {:ok, settings} =
             Config.load_from_string(base_config(fallback_workflow_path: "$#{env_name}"))

    assert settings.routing.fallback_workflow_path == default_settings.routing.fallback_workflow_path
    assert File.regular?(settings.routing.fallback_workflow_path)
  end

  test "preserves explicit absolute fallback paths" do
    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    explicit_path = Path.join(System.tmp_dir!(), "explicit-fallback.md")

    assert {:ok, settings} =
             Config.load_from_string(base_config(fallback_workflow_path: explicit_path))

    assert settings.routing.fallback_workflow_path == Path.expand(explicit_path)
  end

  test "loads a hosted fixture config with repo-label routing and shared fallback workflow" do
    fixture_path = Path.expand("../fixtures/kepler/hosted.yml", __DIR__)
    fallback_path = Path.expand("../../priv/templates/WORKFLOW.kepler.template.md", __DIR__)
    workspace_root = Path.join(System.tmp_dir!(), "hosted-kepler-workspaces")
    state_root = Path.join(System.tmp_dir!(), "hosted-kepler-state")

    System.put_env("GITHUB_TOKEN", "kepler-test-token")
    System.put_env("LINEAR_API_KEY", "linear-token")
    System.put_env("LINEAR_WEBHOOK_SECRET", "linear-webhook-secret")
    System.put_env("KEPLER_WORKSPACE_ROOT", workspace_root)
    System.put_env("KEPLER_STATE_ROOT", state_root)
    System.put_env("KEPLER_FALLBACK_WORKFLOW_PATH", fallback_path)

    assert {:ok, settings} = Config.load(fixture_path)

    assert settings.service_name == "Hosted Kepler"
    assert settings.routing.fallback_workflow_path == fallback_path

    assert Enum.map(settings.repositories, & &1.id) == [
             "api",
             "web",
             "worker",
             "docs",
             "ops",
             "events",
             "contracts",
             "admin-ui"
           ]

    assert Enum.map(settings.repositories, & &1.labels) == [
             ["repo:api"],
             ["repo:web"],
             ["repo:worker"],
             ["repo:docs"],
             ["repo:ops"],
             ["repo:events"],
             ["repo:contracts"],
             ["repo:admin-ui"]
           ]
  end

  test "loads the committed deploy config with env-backed secrets and repo routing" do
    config_path = Path.expand("../../kepler.yml", __DIR__)
    workspace_root = Path.join(System.tmp_dir!(), "deploy-workspaces")
    state_root = Path.join(System.tmp_dir!(), "deploy-state")

    System.delete_env("LINEAR_API_KEY")
    System.put_env("LINEAR_CLIENT_ID", "linear-client-id")
    System.put_env("LINEAR_CLIENT_SECRET", "linear-client-secret")
    System.put_env("LINEAR_WEBHOOK_SECRET", "linear-webhook-secret")
    System.put_env("GITHUB_APP_ID", "123456")
    System.put_env("GITHUB_APP_PRIVATE_KEY", sample_private_key())
    System.put_env("KEPLER_WORKSPACE_ROOT", workspace_root)
    System.put_env("KEPLER_STATE_ROOT", state_root)
    System.put_env("KEPLER_API_TOKEN", "ops-token")

    assert {:ok, settings} = Config.load(config_path)

    assert settings.service_name == "Kepler"
    assert settings.server.api_token == "ops-token"
    assert settings.linear.client_id == "linear-client-id"
    assert settings.linear.client_secret == "linear-client-secret"
    assert settings.linear.api_key == nil
    assert Schema.linear_auth_mode(settings.linear) == :client_credentials
    assert settings.github.app_id == "123456"
    assert settings.github.private_key =~ "BEGIN PRIVATE KEY"
    assert settings.workspace.root == Path.expand(workspace_root)
    assert settings.state.root == Path.expand(state_root)
    assert settings.limits.max_concurrent_runs == 1

    assert Enum.map(settings.repositories, & &1.id) == [
             "api",
             "web",
             "worker",
             "docs",
             "ops",
             "events",
             "contracts",
             "admin-ui"
           ]
  end

  defp base_config(opts \\ []) do
    api_key = Keyword.get(opts, :api_key, "\"linear-token\"")
    client_id = Keyword.get(opts, :client_id, "null")
    client_secret = Keyword.get(opts, :client_secret, "null")
    webhook_secret = Keyword.get(opts, :webhook_secret, "\"linear-secret\"")
    fallback_workflow_path = Keyword.get(opts, :fallback_workflow_path)
    server_api_token = Keyword.get(opts, :server_api_token)

    webhook_path_line =
      case Keyword.fetch(opts, :webhook_path) do
        {:ok, value} -> ~s(\n  webhook_path: "#{value}")
        :error -> ""
      end

    fallback_workflow_path_line =
      if is_binary(fallback_workflow_path) do
        "\nrouting:\n  fallback_workflow_path: #{fallback_workflow_path}\n  ambiguous_choice_limit: 3"
      else
        ""
      end

    server_block =
      if is_binary(server_api_token) do
        "server:\n  api_token: #{server_api_token}\n"
      else
        ""
      end

    """
    service_name: "Kepler"
    #{server_block}linear:
      api_key: #{api_key}
      client_id: #{client_id}
      client_secret: #{client_secret}
      webhook_secret: #{webhook_secret}#{webhook_path_line}
    github:
      bot_name: "Kepler Bot"
      bot_email: "kepler@example.com"
    #{fallback_workflow_path_line}
    repositories:
      - id: "repo-api"
        full_name: "example/repo-api"
        clone_url: "https://github.com/example/repo-api.git"
    """
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp sample_private_key do
    """
    -----BEGIN PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCQdJTm4Gfw9xy/
    CAsaiqy4w6FUAmWeDlAScepyjMqeGahTDMy2BPY9gJTU9TPrIdthYe0adB/3ZePj
    8j7byMwfhdspMD7ggs6sRKCfwHBfur0aiYhOOz2MkVmhgFaQHarLQ2S1x6VAht8Z
    eCYvU1dSbBuXE90haHKMraYaE6HEF3SA5mK5/2DFz/8aKX8MoTcI4vt9lI57m1BY
    vpHw5ffbQqRKJwUMCyxiGGwsTfJ25aX1sjiX9qEJq50xyQc5Zjjzq0Q1okK76ooI
    mJMrAY/WL/JJQltxgD0+GeGxdV2bpEv35PbaEnfQzQNRwPCMKkmQVL0/ttqLgiz8
    NDMkcCRjAgMBAAECggEANKvNf0FjpOD1glIUemEGCXiLYm5dTvw5BgCzU4Eyf+Mr
    FN0d52B3yIURv3SIsbtumltycKrW3QYxyfOSJ+FXTEcqWiJVStdnNDjxuE4aq00T
    lpF/Occv8gktfU2mQnYOyH6SQhXBk32Z61d71NW2iT8R8Ew13PCQk+rdHbT6ztyS
    SZQPdLs0jFK5yR34N2wkqTrKhOj+xtybU5hCgRHTP13wnMXYN3yoJpYo0x/TROox
    RCrYw/c++A4MjqlXOUCm03DuIGPjtXVTfWBdNqPy6wXXtKCOx45aJdkBE9Pp7R5X
    imr6UbG+LSw2srKwakAsamdbQgseANJZocSbB6lTgQKBgQDAvTzVnnMf4gfiu7NW
    tHpEcDQAPql0zaHvjF5RDwdVqDgcva1nO0ZXxvrtn30QkibHIEG//WGH0U2j2N4Z
    ymbHCFLD/TEdScR15KEc5s/Dl4D3ztBK6WvB17J/YezoqaXBO8lC4njQn7zc8E7B
    4wOiSuaWj0Mv4plWM+IRRISDiQKBgQC/3lWMq6y4y7TY9sLvSv4bw0jd8B45/eZ/
    6DEM7lYPSelcqtTAudVgGTR4MbRyFXP757xwN63V8xBcoO6iq9l6GmZ0NSnhuYeZ
    uabJPT1v3b5KVCH62Ng2nq2Wc/1h0nO8b3YSG0upxj/Ykoo7YLlk6HxnNb11OTuE
    jCzMo3OxiwKBgFyx5nMajGW2EHLUMREvJWqKyAeiG1+IkiwiRy4W20Ev8SSpeJ8g
    W9lVYlMsFDsG/01fTx/l3aUzXXLClzayKDHq59tIhvl+A9VrSq0auKtpzuXfej+8
    +U01zqwCzaysAoLnnQjk4JP9bxiXHlmTM6k2+qVIa1i5U2Oo+j2xxUV5AoGAd0ra
    L+MRObhV0cviuXsL8OEDLhI8CNxm8sG/tYV99nWC5T3Fl6ozE1O4fr6QrZnPCiEz
    1SWZLHu6gY0Bshxc1AEUEE55osGCoL6AB4DO8P2ScY5LrjYigBs6XF/ze12o3dED
    PRDBg2YijhnWXkKuIiI2LsmH6RlTev7YX8eEiC8CgYBu7LBm3+VQdxl9dFCY6t2s
    Oibn6VuQR/MwRDFGSlhonKvtMt3LjH5L1vJyR1SzCnoEWiaCzi/ub7REjSEWtzLT
    StqDbYamIMNpjCNq6eyZ2QZnRnWc60j3WcMZDJqkqCS4j2Ng/7YJctSoirGGHeio
    KHrONvcE1BznOLa6SAX6BQ==
    -----END PRIVATE KEY-----
    """
  end
end
