defmodule SymphonyElixir.Kepler.Linear.WebhookTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Linear.Webhook

  test "parses top-level agentSession created payloads" do
    payload = %{
      "action" => "created",
      "agentSession" => %{
        "id" => "session-top-level",
        "issue" => %{"id" => "issue-top-level"},
        "promptContext" => "Issue context"
      }
    }

    assert {:ok,
            %{
              action: "created",
              agent_session_id: "session-top-level",
              issue_id: "issue-top-level",
              prompt_context: "Issue context",
              prompt_body: nil
            }} = Webhook.parse(payload)
  end

  test "parses nested agentSession prompted payloads" do
    payload = %{
      "action" => "prompted",
      "data" => %{
        "agentSession" => %{
          "id" => "session-nested",
          "issue" => %{"id" => "issue-nested"},
          "promptContext" => "Prompt context"
        },
        "agentActivity" => %{"body" => "Please continue"}
      }
    }

    assert {:ok,
            %{
              action: "prompted",
              agent_session_id: "session-nested",
              issue_id: "issue-nested",
              prompt_context: "Prompt context",
              prompt_body: "Please continue"
            }} = Webhook.parse(payload)
  end

  test "parses top-level agentSession prompted payloads with nested content bodies" do
    payload = %{
      "action" => "prompted",
      "agentSession" => %{
        "id" => "session-top-level-prompt",
        "issue" => %{"id" => "issue-top-level-prompt"},
        "promptContext" => "Prompt context"
      },
      "agentActivity" => %{
        "content" => %{"body" => "frontend"}
      }
    }

    assert {:ok,
            %{
              action: "prompted",
              agent_session_id: "session-top-level-prompt",
              issue_id: "issue-top-level-prompt",
              prompt_context: "Prompt context",
              prompt_body: "frontend"
            }} = Webhook.parse(payload)
  end

  test "rejects non-agent-session webhook payloads" do
    payload = %{
      "action" => "issueAssignedToYou",
      "type" => "AppUserNotification",
      "notification" => %{"issueId" => "issue-1"}
    }

    assert {:error, :unsupported_agent_session_webhook} = Webhook.parse(payload)
  end
end
