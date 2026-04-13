defmodule SymphonyElixir.Kepler.Linear.Webhook do
  @moduledoc """
  Normalizes incoming Linear Agent Session webhook payloads.
  """

  @type t :: %{
          action: String.t(),
          agent_session_id: String.t(),
          issue_id: String.t(),
          prompt_context: String.t() | nil,
          prompt_body: String.t() | nil
        }

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"action" => action} = payload) when action in ["created", "prompted"] do
    data = Map.get(payload, "data", %{})
    agent_session = agent_session_payload(data)

    with session_id when is_binary(session_id) <- agent_session["id"] || data["id"],
         issue_id when is_binary(issue_id) <- issue_id(agent_session, data) do
      {:ok,
       %{
         action: action,
         agent_session_id: session_id,
         issue_id: issue_id,
         prompt_context: agent_session["promptContext"] || data["promptContext"],
         prompt_body: prompt_body(action, payload, data)
       }}
    else
      _ -> {:error, :invalid_agent_session_webhook}
    end
  end

  def parse(_payload), do: {:error, :unsupported_agent_session_webhook}

  defp agent_session_payload(%{"agentSession" => %{} = agent_session}), do: agent_session
  defp agent_session_payload(%{} = data), do: data

  defp issue_id(agent_session, data) do
    get_in(agent_session, ["issue", "id"]) || get_in(data, ["issue", "id"]) || data["issueId"]
  end

  defp prompt_body("prompted", payload, data) do
    get_in(payload, ["agentActivity", "body"]) ||
      get_in(data, ["agentActivity", "body"]) ||
      get_in(data, ["prompt", "body"])
  end

  defp prompt_body(_action, _payload, _data), do: nil
end
