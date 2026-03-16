defmodule SymphonyElixir.TrackerComponentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Adf
  alias SymphonyElixir.Linear.Issue, as: LinearIssue
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.SemanticState

  describe "semantic tracker states" do
    test "normalizes and categorizes supported states" do
      assert SemanticState.all() == ~w(backlog queued active review merge rework terminal)
      assert SemanticState.dispatchable() == ~w(queued active merge rework)
      assert SemanticState.hold() == ~w(backlog review)

      assert SemanticState.normalize(" Active ") == "active"
      assert SemanticState.normalize("terminal") == "terminal"
      assert SemanticState.normalize("   ") == nil
      assert SemanticState.normalize("unknown") == nil
      assert SemanticState.normalize(:active) == nil

      assert SemanticState.terminal?(" terminal ")
      refute SemanticState.terminal?("active")
      refute SemanticState.terminal?(nil)
    end
  end

  describe "jira adf helpers" do
    test "normalizes plain text and adf documents" do
      assert Adf.to_plain_text(nil) == nil
      assert Adf.to_plain_text("  hello  ") == "hello"
      assert Adf.to_plain_text("   ") == nil

      document = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "One"}]},
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "text", "text" => "Two"},
              %{"type" => "hardBreak"},
              %{"type" => "text", "text" => "Three"}
            ]
          }
        ]
      }

      assert Adf.to_plain_text(document) == "One\n\nTwo\nThree"
      assert Adf.to_plain_text(%{"content" => [%{"text" => " Nested "}]}) == "Nested"
      assert Adf.to_plain_text(%{"content" => [%{"type" => "hardBreak"}]}) == nil
      assert Adf.to_plain_text(%{}) == nil
      assert Adf.to_plain_text(123) == nil
    end

    test "builds minimal documents from text" do
      assert Adf.from_text(nil) == %{
               "version" => 1,
               "type" => "doc",
               "content" => [%{"type" => "paragraph", "content" => []}]
             }

      assert Adf.from_text("One\nTwo\n\nThree") == %{
               "version" => 1,
               "type" => "doc",
               "content" => [
                 %{
                   "type" => "paragraph",
                   "content" => [
                     %{"type" => "text", "text" => "One"},
                     %{"type" => "hardBreak"},
                     %{"type" => "text", "text" => "Two"}
                   ]
                 },
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "text" => "Three"}]
                 }
               ]
             }
    end
  end

  describe "linear issue helpers" do
    test "returns label names unchanged" do
      assert LinearIssue.label_names(%LinearIssue{labels: ["bug", "backend"]}) == ["bug", "backend"]
    end
  end

  describe "memory tracker adapter" do
    setup do
      issue = %Issue{id: "issue-1", identifier: "ENG-1", state: "In Progress", title: "Test issue"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, :ignored])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      {:ok, issue: issue}
    end

    test "filters issues and emits tracker events", %{issue: issue} do
      assert {:ok, [^issue]} = Memory.fetch_candidate_issues()
      assert {:ok, [^issue]} = Memory.fetch_issues_by_states([" in progress ", 123])
      assert {:ok, [^issue]} = Memory.fetch_issue_states_by_ids(["issue-1"])
      assert {:ok, ^issue} = Memory.get_issue("ENG-1")
      assert {:error, :issue_not_found} = Memory.get_issue("ENG-404")
      assert {:ok, []} = Memory.list_comments("ENG-1")

      assert :ok = Memory.create_comment("issue-1", "comment")
      assert_receive {:memory_tracker_comment, "issue-1", "comment"}

      assert :ok = Memory.update_comment("comment-1", "updated", "issue-1")
      assert_receive {:memory_tracker_comment_update, "comment-1", "updated", "issue-1"}

      assert :ok = Memory.update_issue_state("issue-1", "Done")
      assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

      assert :ok = Memory.attach_url("issue-1", "https://example.com/task", "Task")
      assert_receive {:memory_tracker_attach_url, "issue-1", "https://example.com/task", "Task"}

      assert :ok = Memory.attach_pr("issue-1", "https://github.com/acme/repo/pull/1", "PR")

      assert_receive {:memory_tracker_attach_pr, "issue-1", "https://github.com/acme/repo/pull/1", "PR"}

      assert {:ok, %{filename: "proof.txt", issue_id: "issue-1"}} =
               Memory.upload_attachment("issue-1", "proof.txt", "text/plain", ["pro", "of"])

      assert_receive {:memory_tracker_upload_attachment, "issue-1", "proof.txt", "text/plain", "proof"}
    end

    test "silently drops tracker events when no recipient is configured" do
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      assert :ok = Memory.create_comment("issue-1", "comment")
      refute_receive {:memory_tracker_comment, _, _}
    end
  end

  describe "tracker adapter boundary" do
    setup do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      issue = %Issue{id: "issue-1", identifier: "ENG-1", state: "In Progress", title: "Memory issue"}

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      {:ok, issue: issue}
    end

    test "delegates reads and default-argument writes through the selected adapter", %{issue: issue} do
      assert Tracker.adapter() == Memory
      assert {:ok, [^issue]} = Tracker.fetch_candidate_issues()
      assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["in progress"])
      assert {:ok, [^issue]} = Tracker.fetch_issue_states_by_ids(["issue-1"])
      assert {:ok, ^issue} = Tracker.get_issue("ENG-1")
      assert {:ok, []} = Tracker.list_comments("ENG-1")

      assert :ok = Tracker.create_comment("issue-1", "comment")
      assert_receive {:memory_tracker_comment, "issue-1", "comment"}

      assert :ok = Tracker.update_comment("comment-1", "updated")
      assert_receive {:memory_tracker_comment_update, "comment-1", "updated", nil}

      assert :ok = Tracker.update_issue_state("issue-1", "Done")
      assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

      assert :ok = Tracker.attach_url("issue-1", "https://example.com/task")
      assert_receive {:memory_tracker_attach_url, "issue-1", "https://example.com/task", nil}

      assert :ok = Tracker.attach_pr("issue-1", "https://github.com/acme/repo/pull/1")
      assert_receive {:memory_tracker_attach_pr, "issue-1", "https://github.com/acme/repo/pull/1", nil}

      assert {:ok, %{filename: "proof.txt", issue_id: "issue-1"}} =
               Tracker.upload_attachment("issue-1", "proof.txt", "text/plain", "proof")

      assert_receive {:memory_tracker_upload_attachment, "issue-1", "proof.txt", "text/plain", "proof"}
    end
  end
end
