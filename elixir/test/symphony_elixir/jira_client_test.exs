defmodule SymphonyElixir.JiraClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.{Adf, Client}

  test "jira config parses auth, state map, and semantic helpers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_site_url: "https://example.atlassian.net",
      tracker_project_key: "ENG",
      tracker_assignee: "me",
      tracker_state_map: %{
        queued: ["Todo"],
        active: ["In Progress"],
        review: ["Human Review"],
        terminal: ["Done", "Cancelled"]
      },
      tracker_auth_type: "api_token",
      tracker_auth_email: "jira@example.com",
      tracker_auth_api_token: "jira-secret"
    )

    assert Config.tracker_kind() == "jira"
    assert Config.tracker_assignee() == "me"
    assert Config.jira_site_url() == "https://example.atlassian.net"
    assert Config.jira_project_key() == "ENG"
    assert Config.jira_auth_type() == "api_token"
    assert Config.jira_auth_email() == "jira@example.com"
    assert Config.jira_api_token() == "jira-secret"
    assert Config.tracker_active_states() == ["Todo", "In Progress"]
    assert Config.tracker_terminal_states() == ["Done", "Cancelled"]
    assert Config.semantic_state_for_tracker_state("Human Review") == "review"
    assert Config.target_tracker_state_for_semantic_state("terminal") == "Done"
    assert :ok = Config.validate!()
  end

  test "jira ADF helpers convert between text and minimal docs" do
    text = "First line\nSecond line\n\nNext paragraph"
    adf = Adf.from_text(text)

    assert adf["type"] == "doc"
    assert Adf.to_plain_text(adf) == text
  end

  test "jira client builds JQL and normalizes issue payloads" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_site_url: "https://example.atlassian.net",
      tracker_project_key: "ENG",
      tracker_state_map: %{
        active: ["In Progress"],
        terminal: ["Done"]
      },
      tracker_blocks_inward: ["depends on"]
    )

    assert Client.build_candidate_jql_for_test("ENG", "currentUser()", ["Todo", "In Progress"]) ==
             ~s|project = "ENG" AND assignee = currentUser() AND status in ("Todo", "In Progress") ORDER BY created ASC|

    raw_issue = %{
      "id" => "1001",
      "key" => "ENG-1",
      "fields" => %{
        "summary" => "Implement Jira parity",
        "description" => Adf.from_text("Paragraph 1\nParagraph 2"),
        "priority" => %{"name" => "High"},
        "status" => %{
          "id" => "31",
          "name" => "In Progress",
          "statusCategory" => %{"key" => "indeterminate"}
        },
        "labels" => ["Backend", "Tracker"],
        "assignee" => %{"accountId" => "acct-1", "displayName" => "Kevin"},
        "created" => "2026-01-01T00:00:00.000+0000",
        "updated" => "2026-01-02T00:00:00.000+0000",
        "issuelinks" => [
          %{
            "type" => %{"inward" => "depends on"},
            "inwardIssue" => %{
              "id" => "1002",
              "key" => "ENG-2",
              "fields" => %{"status" => %{"name" => "Done"}}
            }
          }
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue)

    assert issue.identifier == "ENG-1"
    assert issue.description == "Paragraph 1\nParagraph 2"
    assert issue.priority == 2
    assert issue.state == "In Progress"
    assert issue.semantic_state == "active"
    assert issue.url == "https://example.atlassian.net/browse/ENG-1"
    assert issue.labels == ["backend", "tracker"]
    assert issue.blocked_by == [%{id: "1002", identifier: "ENG-2", state: "Done"}]
    assert issue.assignee_id == "acct-1"
  end

  test "jira client resolves transitions and comments from raw payloads" do
    transitions = %{
      "transitions" => [
        %{"id" => "11", "to" => %{"name" => "Todo"}},
        %{"id" => "31", "to" => %{"name" => "Human Review"}}
      ]
    }

    assert {:ok, "31"} = Client.resolve_transition_id_for_test(transitions, "Human Review")
    assert {:error, :jira_transition_not_found} = Client.resolve_transition_id_for_test(transitions, "Missing")

    comment =
      Client.normalize_comment_for_test(
        %{
          "id" => "comment-1",
          "body" => Adf.from_text("Workpad"),
          "author" => %{"accountId" => "acct-1", "displayName" => "Kevin"},
          "created" => "2026-01-03T00:00:00.000+0000",
          "updated" => "2026-01-04T00:00:00.000+0000",
          "self" => "https://example.atlassian.net/rest/api/3/comment/comment-1"
        },
        "ENG-1"
      )

    assert comment.id == "comment-1"
    assert comment.issue_id == "ENG-1"
    assert comment.body == "Workpad"
    assert comment.author_id == "acct-1"
    assert comment.author_name == "Kevin"
  end

  test "jira comment updates require an issue id to preserve project scoping" do
    assert {:error, :jira_issue_id_required_for_comment_update} =
             Client.update_comment("comment-1", "updated workpad")
  end
end
