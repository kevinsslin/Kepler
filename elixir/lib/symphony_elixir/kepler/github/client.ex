defmodule SymphonyElixir.Kepler.GitHub.Client do
  @moduledoc """
  GitHub App helper for Kepler workspace bootstrap and pull request publishing.
  """

  require Logger

  alias SymphonyElixir.Kepler.Config

  @api_accept "application/vnd.github+json"

  @type auth :: %{
          token: String.t(),
          installation_id: integer() | nil
        }

  @type pull_request_ref :: %{
          number: integer(),
          url: String.t()
        }

  @spec workspace_env(SymphonyElixir.Kepler.Config.Schema.Repository.t()) ::
          {:ok, map()} | {:error, term()}
  def workspace_env(repo) do
    with {:ok, auth} <- installation_auth(repo) do
      {:ok,
       git_http_env(auth.token)
       |> Map.merge(%{
         "GH_TOKEN" => auth.token,
         "GITHUB_TOKEN" => auth.token,
         "GIT_AUTHOR_NAME" => Config.settings!().github.bot_name,
         "GIT_AUTHOR_EMAIL" => Config.settings!().github.bot_email,
         "GIT_COMMITTER_NAME" => Config.settings!().github.bot_name,
         "GIT_COMMITTER_EMAIL" => Config.settings!().github.bot_email
       })}
    end
  end

  @spec installation_auth(SymphonyElixir.Kepler.Config.Schema.Repository.t()) ::
          {:ok, auth()} | {:error, term()}
  def installation_auth(repo) do
    github = Config.settings!().github

    cond do
      host_token = System.get_env("GITHUB_TOKEN") ->
        {:ok, %{token: host_token, installation_id: repo.github_installation_id}}

      github_app_configured?(github) ->
        with {:ok, jwt} <- app_jwt(),
             {:ok, installation_id} <- resolve_installation_id(repo, jwt),
             {:ok, token} <- create_installation_token(installation_id, jwt) do
          {:ok, %{token: token, installation_id: installation_id}}
        end

      true ->
        {:error, :missing_github_auth}
    end
  end

  @spec find_open_pull_request(SymphonyElixir.Kepler.Config.Schema.Repository.t(), String.t()) ::
          {:ok, pull_request_ref() | nil} | {:error, term()}
  def find_open_pull_request(repo, branch) when is_binary(branch) and branch != "" do
    with {:ok, auth} <- installation_auth(repo),
         {owner, _name} <- split_full_name(repo.full_name),
         {:ok, response} <-
           github_get(
             "/repos/#{repo.full_name}/pulls?state=open&head=#{owner}:#{URI.encode(branch)}",
             auth.token
           ) do
      case response do
        [%{"number" => number, "html_url" => html_url} | _rest]
        when is_integer(number) and is_binary(html_url) ->
          {:ok, %{number: number, url: html_url}}

        _ ->
          {:ok, nil}
      end
    end
  end

  @spec create_pull_request(
          SymphonyElixir.Kepler.Config.Schema.Repository.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def create_pull_request(repo, branch, title, body)
      when is_binary(branch) and is_binary(title) and is_binary(body) do
    with {:ok, auth} <- installation_auth(repo),
         {:ok, response} <-
           github_post(
             "/repos/#{repo.full_name}/pulls",
             auth.token,
             %{
               title: title,
               head: branch,
               base: repo.default_branch,
               body: body,
               draft: false
             }
           ),
         html_url when is_binary(html_url) <- response["html_url"] do
      {:ok, html_url}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pull_request_create_failed}
    end
  end

  @spec update_pull_request(
          SymphonyElixir.Kepler.Config.Schema.Repository.t(),
          integer(),
          String.t() | nil,
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def update_pull_request(repo, number, title, body)
      when is_integer(number) and (is_binary(title) or is_nil(title)) and is_binary(body) do
    with {:ok, auth} <- installation_auth(repo),
         {:ok, response} <-
           github_patch(
             "/repos/#{repo.full_name}/pulls/#{number}",
             auth.token,
             update_pull_request_payload(title, body)
           ),
         html_url when is_binary(html_url) <- response["html_url"] do
      {:ok, html_url}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :pull_request_update_failed}
    end
  end

  defp update_pull_request_payload(nil, body), do: %{body: body}
  defp update_pull_request_payload(title, body), do: %{title: title, body: body}

  @spec app_jwt() :: {:ok, String.t()} | {:error, term()}
  def app_jwt do
    github = Config.settings!().github

    if github_app_configured?(github) do
      with {:ok, private_key} <- decode_private_key(github.private_key) do
        now = System.system_time(:second)

        header =
          %{"alg" => "RS256", "typ" => "JWT"}
          |> Jason.encode!()
          |> Base.url_encode64(padding: false)

        payload =
          %{
            "iat" => now - 60,
            "exp" => now + 540,
            "iss" => github.app_id
          }
          |> Jason.encode!()
          |> Base.url_encode64(padding: false)

        signing_input = header <> "." <> payload
        signature = :public_key.sign(signing_input, :sha256, private_key)
        {:ok, signing_input <> "." <> Base.url_encode64(signature, padding: false)}
      end
    else
      {:error, :missing_github_app_credentials}
    end
  end

  defp resolve_installation_id(repo, jwt) do
    case repo.github_installation_id do
      installation_id when is_integer(installation_id) ->
        {:ok, installation_id}

      _ ->
        with {:ok, response} <- github_get("/repos/#{repo.full_name}/installation", jwt) do
          installation_id_from_response(response)
        end
    end
  end

  defp installation_id_from_response(%{"id" => installation_id}) when is_integer(installation_id),
    do: {:ok, installation_id}

  defp installation_id_from_response(_response), do: {:error, :github_installation_not_found}

  defp create_installation_token(installation_id, jwt) when is_integer(installation_id) do
    with {:ok, response} <-
           github_post("/app/installations/#{installation_id}/access_tokens", jwt, %{}, app_jwt: true),
         token when is_binary(token) <- response["token"] do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_installation_token_missing}
    end
  end

  defp decode_private_key(private_key_pem) when is_binary(private_key_pem) do
    case :public_key.pem_decode(private_key_pem) do
      [entry | _rest] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      _ ->
        {:error, :invalid_github_private_key}
    end
  end

  defp git_http_env(token) when is_binary(token) do
    auth_value = "AUTHORIZATION: basic " <> Base.encode64("x-access-token:" <> token)

    %{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
      "GIT_CONFIG_VALUE_0" => auth_value
    }
  end

  defp github_get(path, token) do
    request(:get, path, token, nil, [])
  end

  defp github_post(path, token, body, opts \\ []) do
    request(:post, path, token, body, opts)
  end

  defp github_patch(path, token, body, opts \\ []) do
    request(:patch, path, token, body, opts)
  end

  defp request(method, path, token, body, opts) when method in [:get, :post, :patch] do
    headers =
      [
        {"Accept", @api_accept},
        {"Authorization", authorization_header(token, Keyword.get(opts, :app_jwt, false))}
      ]

    request_opts =
      [
        url: github_url(path),
        headers: headers
      ] ++
        case {method, body} do
          {verb, %{} = payload} when verb in [:post, :patch] -> [json: payload]
          _ -> []
        end

    case Req.request([method: method] ++ request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        Logger.warning("Kepler GitHub request failed method=#{method} path=#{path} status=#{status} body=#{inspect(response_body)}")

        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp authorization_header(token, true), do: "Bearer " <> token
  defp authorization_header(token, false), do: "Bearer " <> token

  defp github_url(path) do
    String.trim_trailing(Config.settings!().github.api_url, "/") <> path
  end

  defp split_full_name(full_name) do
    case String.split(full_name, "/", parts: 2) do
      [owner, name] -> {owner, name}
      _ -> raise ArgumentError, "invalid repository full_name: #{inspect(full_name)}"
    end
  end

  defp github_app_configured?(github) do
    is_binary(github.app_id) and github.app_id != "" and
      is_binary(github.private_key) and github.private_key != ""
  end
end
