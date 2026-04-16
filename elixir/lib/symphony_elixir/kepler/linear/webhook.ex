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
    agent_session = agent_session_payload(payload, data)

    with session_id when is_binary(session_id) <- session_id(agent_session, data, payload),
         issue_id when is_binary(issue_id) <- issue_id(agent_session, data, payload) do
      {:ok,
       %{
         action: action,
         agent_session_id: session_id,
         issue_id: issue_id,
         prompt_context: prompt_context(agent_session, data, payload),
         prompt_body: prompt_body(action, agent_session, data, payload)
       }}
    else
      _ -> {:error, :invalid_agent_session_webhook}
    end
  end

  def parse(_payload), do: {:error, :unsupported_agent_session_webhook}

  defp agent_session_payload(%{"agentSession" => %{} = agent_session}, _data), do: agent_session
  defp agent_session_payload(_payload, %{"agentSession" => %{} = agent_session}), do: agent_session
  defp agent_session_payload(%{} = payload, _data), do: payload

  defp session_id(agent_session, data, payload) do
    agent_session["id"] || data["id"] || payload["id"]
  end

  defp issue_id(agent_session, data, payload) do
    get_in(agent_session, ["issue", "id"]) ||
      get_in(data, ["issue", "id"]) ||
      get_in(payload, ["issue", "id"]) ||
      data["issueId"] ||
      payload["issueId"]
  end

  defp prompt_context(agent_session, data, payload) do
    agent_session["promptContext"] || data["promptContext"] || payload["promptContext"]
  end

  defp prompt_body("prompted", agent_session, data, payload) do
    agent_session["promptBody"] ||
      activity_body(Map.get(payload, "agentActivity")) ||
      activity_body(Map.get(data, "agentActivity")) ||
      activity_body(Map.get(payload, "prompt")) ||
      activity_body(Map.get(data, "prompt"))
  end

  defp prompt_body(_action, _agent_session, _data, _payload), do: nil

  defp activity_body(%{} = activity) do
    activity["body"] ||
      get_in(activity, ["content", "body"])
  end

  defp activity_body(_activity), do: nil
end
