defmodule SymphonyElixir.Kepler.PullRequestBodyTest do
  use ExUnit.Case

  alias SymphonyElixir.Kepler.Config.Schema.Repository
  alias SymphonyElixir.Kepler.Execution.PullRequestBody
  alias SymphonyElixir.Kepler.Run

  test "build renders a frontend report with tracked local evidence" do
    workspace = git_workspace!("kepler-pr-body-frontend")

    write_binary_file!(workspace, ".kepler/evidence/header-before.png")
    write_binary_file!(workspace, ".kepler/evidence/header-after.png")
    git!(workspace, ["add", ".kepler/evidence/header-before.png", ".kepler/evidence/header-after.png"])
    git!(workspace, ["commit", "-m", "Add frontend evidence fixtures"])
    File.mkdir_p!(Path.join(workspace, ".kepler"))

    File.write!(
      Path.join(workspace, ".kepler/pr-report.json"),
      Jason.encode!(%{
        "change_type" => "frontend",
        "summary" => ["Implemented dashboard tweak"],
        "validation" => [
          %{"command" => "pnpm lint", "kind" => "lint", "result" => "passed"}
        ],
        "frontend_evidence" => [
          %{
            "label" => "Dashboard header",
            "before_path" => ".kepler/evidence/header-before.png",
            "after_path" => ".kepler/evidence/header-after.png",
            "note" => "Captured in local dev mode"
          }
        ],
        "risks" => ["No visual diff for spacing changes outside the captured viewport"]
      })
    )

    assert {:ok, body} =
             PullRequestBody.build(
               workspace,
               repository("example-org/example-web"),
               "kepler/APP-42",
               run("APP-42", "Refine dashboard header")
             )

    assert body =~ "## Summary"
    assert body =~ "Implemented dashboard tweak"
    assert body =~ "https://linear.app/example-workspace/issue/APP-42"
    assert body =~ "## Validation"
    assert body =~ "[lint] pnpm lint => passed"
    assert body =~ "## Frontend Evidence"
    assert body =~ "Dashboard header"
    assert body =~ "blob/kepler/APP-42/.kepler/evidence/header-before.png?raw=1"
    assert body =~ "blob/kepler/APP-42/.kepler/evidence/header-after.png?raw=1"
    assert body =~ "Captured in local dev mode"
    assert body =~ "## Risks"
  end

  test "build prefers explicit frontend evidence urls over derived branch paths" do
    workspace = git_workspace!("kepler-pr-body-frontend-urls")
    File.mkdir_p!(Path.join(workspace, ".kepler"))

    File.write!(
      Path.join(workspace, ".kepler/pr-report.json"),
      Jason.encode!(%{
        "change_type" => "frontend",
        "summary" => ["Refined settlement page"],
        "validation" => [
          %{"command" => "pnpm lint", "kind" => "lint", "result" => "passed"}
        ],
        "frontend_evidence" => [
          %{
            "label" => "Settlement page",
            "before_path" => ".kepler/evidence/local-before.png",
            "after_path" => ".kepler/evidence/local-after.png",
            "before_url" => "https://cdn.example.com/before.png",
            "after_url" => "https://cdn.example.com/after.png"
          }
        ]
      })
    )

    assert {:ok, body} =
             PullRequestBody.build(
               workspace,
               repository("example-org/example-web"),
               "kepler/APP-99",
               run("APP-99", "Refine settlement page")
             )

    assert body =~ "https://cdn.example.com/before.png"
    assert body =~ "https://cdn.example.com/after.png"
    refute body =~ "blob/kepler/APP-99/.kepler/evidence/local-before.png"
  end

  test "build fails when the structured report is missing" do
    workspace = git_workspace!("kepler-pr-body-missing")

    assert {:error, :missing_pr_report} =
             PullRequestBody.build(
               workspace,
               repository("example-org/example-contracts"),
               "kepler/APP-77",
               run("APP-77", "Patch contract guard")
             )
  end

  test "build fails when backend report lacks passing test evidence" do
    workspace = git_workspace!("kepler-pr-body-backend")
    File.mkdir_p!(Path.join(workspace, ".kepler"))

    File.write!(
      Path.join(workspace, ".kepler/pr-report.json"),
      Jason.encode!(%{
        "change_type" => "backend",
        "tests_required" => true,
        "summary" => ["Patched settlement worker retry logic"],
        "validation" => [
          %{"command" => "mix format --check-formatted", "kind" => "format", "result" => "passed"},
          %{"command" => "mix credo", "kind" => "lint", "result" => "passed"}
        ]
      })
    )

    assert {:error, :missing_passing_test_evidence} =
             PullRequestBody.build(
               workspace,
               repository("example-org/example-worker"),
               "kepler/APP-108",
               run("APP-108", "Patch settlement worker")
             )
  end

  test "build fails when frontend evidence file is not committed in HEAD" do
    workspace = git_workspace!("kepler-pr-body-untracked")

    write_binary_file!(workspace, ".kepler/evidence/header-after.png")
    File.mkdir_p!(Path.join(workspace, ".kepler"))

    File.write!(
      Path.join(workspace, ".kepler/pr-report.json"),
      Jason.encode!(%{
        "change_type" => "frontend",
        "summary" => ["Adjusted header spacing"],
        "validation" => [
          %{"command" => "pnpm lint", "kind" => "lint", "result" => "passed"}
        ],
        "frontend_evidence" => [
          %{
            "label" => "Header",
            "after_path" => ".kepler/evidence/header-after.png"
          }
        ]
      })
    )

    assert {:error, {:uncommitted_frontend_evidence_file, ".kepler/evidence/header-after.png"}} =
             PullRequestBody.build(
               workspace,
               repository("example-org/example-web"),
               "kepler/APP-109",
               run("APP-109", "Adjust header spacing")
             )
  end

  defp git_workspace!(prefix) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(workspace)
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Kepler Test"])
    git!(workspace, ["config", "user.email", "kepler@example.com"])

    File.write!(Path.join(workspace, "README.md"), "# Test workspace\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "Initial commit"])

    workspace
  end

  defp git!(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp write_binary_file!(workspace, relative_path) do
    absolute_path = Path.join(workspace, relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
  end

  defp repository(full_name) do
    %Repository{
      id: "repo",
      full_name: full_name,
      clone_url: "https://github.com/#{full_name}.git",
      default_branch: "main",
      workflow_path: "WORKFLOW.md",
      provider: "codex",
      labels: [],
      team_keys: [],
      project_ids: [],
      project_slugs: []
    }
  end

  defp run(identifier, title) do
    Run.new(%{
      linear_issue_id: identifier,
      linear_issue_identifier: identifier,
      linear_issue_title: title,
      linear_issue_url: "https://linear.app/example-workspace/issue/#{identifier}",
      linear_agent_session_id: "session-#{identifier}"
    })
  end
end
