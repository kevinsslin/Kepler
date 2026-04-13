defmodule SymphonyElixir.Kepler.Execution.PullRequestBody do
  @moduledoc """
  Validates and renders the structured PR handoff report produced by hosted Kepler workflows.
  """

  alias SymphonyElixir.Kepler.Config.Schema.Repository
  alias SymphonyElixir.Kepler.Run

  @report_candidates [".kepler/pr-report.json", ".kepler/pr_report.json"]
  @test_kinds MapSet.new(["test", "integration", "e2e", "contract"])
  @passing_results MapSet.new(["passed", "pass", "ok", "green", "success"])

  @type validation_entry :: %{
          command: String.t(),
          kind: String.t() | nil,
          result: String.t() | nil
        }

  @type frontend_evidence :: %{
          label: String.t(),
          before_path: String.t() | nil,
          after_path: String.t() | nil,
          before_url: String.t() | nil,
          after_url: String.t() | nil,
          note: String.t() | nil
        }

  @type normalized_report :: %{
          change_type: String.t() | nil,
          tests_required: boolean() | nil,
          summary: [String.t()],
          validation: [validation_entry()],
          blockers: [String.t()],
          risks: [String.t()],
          no_change_reason: String.t() | nil,
          frontend_evidence: [frontend_evidence()]
        }

  @spec build(Path.t(), Repository.t(), String.t() | nil, Run.t()) ::
          {:ok, String.t()} | {:error, term()}
  def build(workspace_path, %Repository{} = repository, branch, %Run{} = run) do
    with {:ok, report} <- load_report(workspace_path),
         :ok <- validate_report(workspace_path, report) do
      {:ok, render_report(report, repository, branch, run)}
    end
  end

  defp load_report(workspace_path) do
    @report_candidates
    |> Enum.map(&Path.join(workspace_path, &1))
    |> Enum.reduce_while({:error, :missing_pr_report}, fn report_path, _acc ->
      case read_report(report_path) do
        {:error, :missing_pr_report} -> {:cont, {:error, :missing_pr_report}}
        result -> {:halt, result}
      end
    end)
  end

  defp read_report(report_path) do
    case File.read(report_path) do
      {:ok, content} ->
        decode_report(report_path, content)

      {:error, :enoent} ->
        {:error, :missing_pr_report}

      {:error, reason} ->
        {:error, {:invalid_pr_report, report_path, reason}}
    end
  end

  defp decode_report(report_path, content) do
    case Jason.decode(content) do
      {:ok, %{} = report} ->
        {:ok, normalize_report(report)}

      {:ok, _decoded} ->
        {:error, {:invalid_pr_report, report_path, :not_a_map}}

      {:error, reason} ->
        {:error, {:invalid_pr_report, report_path, reason}}
    end
  end

  defp normalize_report(report) do
    %{
      change_type: normalize_change_type(Map.get(report, "change_type", Map.get(report, "changeType"))),
      tests_required: normalize_boolean(Map.get(report, "tests_required", Map.get(report, "testsRequired"))),
      summary: normalize_list(Map.get(report, "summary")),
      validation: normalize_validation_entries(Map.get(report, "validation")),
      blockers: normalize_list(Map.get(report, "blockers")),
      risks: normalize_list(Map.get(report, "risks")),
      no_change_reason: normalize_string(Map.get(report, "no_change_reason", Map.get(report, "noChangeReason"))),
      frontend_evidence:
        report
        |> Map.get("frontend_evidence", Map.get(report, "frontendEvidence", []))
        |> normalize_frontend_evidence()
    }
  end

  defp normalize_change_type(value) do
    value
    |> normalize_string()
    |> case do
      "frontend" = normalized -> normalized
      "backend" = normalized -> normalized
      "smart-contract" = normalized -> normalized
      "docs" = normalized -> normalized
      "other" = normalized -> normalized
      _ -> nil
    end
  end

  defp normalize_boolean(value) when is_boolean(value), do: value

  defp normalize_boolean(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp normalize_boolean(_value), do: nil

  defp normalize_validation_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn
      %{} = entry ->
        normalize_validation_entry_map(entry)

      entry ->
        case normalize_string(entry) do
          nil -> []
          command -> [%{command: command, result: nil, kind: nil}]
        end
    end)
  end

  defp normalize_validation_entries(entries) do
    case normalize_string(entries) do
      nil -> []
      command -> [%{command: command, result: nil, kind: nil}]
    end
  end

  defp normalize_validation_entry_map(entry) do
    command =
      normalize_string(Map.get(entry, "command")) ||
        normalize_string(Map.get(entry, "value"))

    if command do
      [
        %{
          command: command,
          result: normalize_string(Map.get(entry, "result")),
          kind: normalize_string(Map.get(entry, "kind"))
        }
      ]
    else
      []
    end
  end

  defp normalize_frontend_evidence(items) when is_list(items) do
    Enum.flat_map(items, fn
      %{} = item ->
        [
          %{
            label: normalize_string(Map.get(item, "label")) || "UI change",
            before_path: normalize_string(Map.get(item, "before_path", Map.get(item, "beforePath"))),
            after_path: normalize_string(Map.get(item, "after_path", Map.get(item, "afterPath"))),
            before_url: normalize_string(Map.get(item, "before_url", Map.get(item, "beforeUrl"))),
            after_url: normalize_string(Map.get(item, "after_url", Map.get(item, "afterUrl"))),
            note: normalize_string(Map.get(item, "note"))
          }
        ]

      _ ->
        []
    end)
  end

  defp normalize_frontend_evidence(_items), do: []

  defp validate_report(workspace_path, report) do
    validators = [
      fn -> validate_summary(report) end,
      fn -> validate_validation_entries(report) end,
      fn -> validate_blockers(report) end,
      fn -> validate_change_type_requirements(workspace_path, report) end
    ]

    Enum.reduce_while(validators, :ok, fn validator, _acc ->
      case validator.() do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_summary(%{summary: [_ | _]}), do: :ok
  defp validate_summary(_report), do: {:error, :missing_pr_summary}

  defp validate_validation_entries(%{validation: entries}) when is_list(entries) and entries != [],
    do: :ok

  defp validate_validation_entries(_report), do: {:error, :missing_pr_validation}

  defp validate_blockers(%{blockers: []}), do: :ok
  defp validate_blockers(%{blockers: _}), do: {:error, :pr_report_contains_blockers}

  defp validate_change_type_requirements(workspace_path, report) do
    case report.change_type do
      "frontend" ->
        validate_frontend_evidence(workspace_path, report.frontend_evidence)

      "backend" ->
        require_passing_tests(report)

      "smart-contract" ->
        require_passing_tests(report)

      "docs" ->
        :ok

      "other" ->
        if report.tests_required, do: require_passing_tests(report), else: :ok

      _ ->
        {:error, :missing_change_type}
    end
  end

  defp require_passing_tests(report) do
    if Enum.any?(report.validation, &passing_test_entry?/1) do
      :ok
    else
      {:error, :missing_passing_test_evidence}
    end
  end

  defp passing_test_entry?(entry) do
    MapSet.member?(@test_kinds, entry.kind || "") and
      MapSet.member?(@passing_results, entry.result || "")
  end

  defp validate_frontend_evidence(_workspace_path, []), do: {:error, :missing_frontend_evidence}

  defp validate_frontend_evidence(workspace_path, evidence_items) do
    evidence_items
    |> Enum.reduce_while(:ok, fn item, _acc ->
      case validate_frontend_evidence_item(workspace_path, item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_frontend_evidence_item(workspace_path, item) do
    case require_after_evidence(item) do
      :ok ->
        case validate_local_evidence_reference(workspace_path, item.before_path, item.before_url) do
          :ok ->
            validate_local_evidence_reference(workspace_path, item.after_path, item.after_url)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp require_after_evidence(item) do
    if item.after_url || item.after_path do
      :ok
    else
      {:error, :missing_frontend_after_evidence}
    end
  end

  defp validate_local_evidence_reference(_workspace_path, _path, url) when is_binary(url), do: :ok
  defp validate_local_evidence_reference(_workspace_path, nil, nil), do: :ok

  defp validate_local_evidence_reference(workspace_path, path, nil) when is_binary(path) do
    absolute_path = Path.join(workspace_path, normalize_relative_path(path))

    if File.exists?(absolute_path) do
      case committed_in_head?(workspace_path, path) do
        {:ok, true} ->
          :ok

        {:ok, false} ->
          {:error, {:uncommitted_frontend_evidence_file, path}}

        {:error, reason} ->
          {:error, {:frontend_evidence_git_check_failed, path, reason}}
      end
    else
      {:error, {:missing_frontend_evidence_file, path}}
    end
  end

  defp render_report(report, repository, branch, run) do
    [
      header_section(run, branch),
      report_meta_section(report),
      markdown_section("Summary", report.summary),
      validation_section(report.validation),
      frontend_evidence_section(report.frontend_evidence, repository, branch),
      markdown_section("Risks", report.risks)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp header_section(run, branch) do
    identifier = run.linear_issue_identifier || run.linear_issue_id || "unknown-issue"
    title = run.linear_issue_title || "Kepler change"

    [
      "Automated Kepler run for `#{identifier}`.",
      "",
      "- Title: #{title}",
      if(run.linear_issue_url, do: "- Linear issue: #{run.linear_issue_url}"),
      "- Branch: `#{branch || "unknown"}`"
    ]
    |> Enum.join("\n")
  end

  defp report_meta_section(report) do
    lines =
      [
        if(report.change_type, do: "- Change type: `#{report.change_type}`"),
        if(not is_nil(report.tests_required), do: "- Tests required: `#{report.tests_required}`"),
        if(report.no_change_reason, do: "- No-change reason: #{report.no_change_reason}")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case lines do
      [] -> nil
      _ -> Enum.join(lines, "\n")
    end
  end

  defp markdown_section(_title, []), do: nil

  defp markdown_section(title, lines) do
    rendered =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("\n", &"- #{&1}")

    if rendered == "" do
      nil
    else
      "## #{title}\n#{rendered}"
    end
  end

  defp validation_section([]), do: nil

  defp validation_section(entries) do
    rendered =
      entries
      |> Enum.map_join("\n", fn entry ->
        parts =
          [
            if(entry.kind, do: "[#{entry.kind}]"),
            entry.command,
            if(entry.result, do: "=> #{entry.result}")
          ]
          |> Enum.reject(&(&1 in [nil, ""]))

        "- " <> Enum.join(parts, " ")
      end)

    "## Validation\n#{rendered}"
  end

  defp frontend_evidence_section([], _repository, _branch), do: nil
  defp frontend_evidence_section(_items, _repository, nil), do: nil

  defp frontend_evidence_section(items, repository, branch) do
    rendered =
      items
      |> Enum.map(&render_frontend_evidence_item(&1, repository, branch))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    if rendered == "" do
      nil
    else
      "## Frontend Evidence\n#{rendered}"
    end
  end

  defp render_frontend_evidence_item(item, repository, branch) do
    before_url = item.before_url || artifact_url(repository, branch, item.before_path)
    after_url = item.after_url || artifact_url(repository, branch, item.after_path)

    body =
      [
        "### #{item.label}",
        render_image("Before", "#{item.label} before", before_url),
        render_image("After", "#{item.label} after", after_url),
        if(item.note, do: "- Note: #{item.note}")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    if body == "### #{item.label}" do
      nil
    else
      body
    end
  end

  defp render_image(_label, _alt, nil), do: nil

  defp render_image(label, alt, url) do
    "#{label}:\n![#{alt}](#{url})"
  end

  defp artifact_url(_repository, _branch, nil), do: nil

  defp artifact_url(%Repository{} = repository, branch, path) do
    encoded_branch = URI.encode(branch)

    encoded_path =
      path
      |> normalize_relative_path()
      |> Path.split()
      |> Enum.map_join("/", &URI.encode/1)

    "https://github.com/#{repository.full_name}/blob/#{encoded_branch}/#{encoded_path}?raw=1"
  end

  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_list(value) do
    case normalize_string(value) do
      nil -> []
      item -> [item]
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_relative_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim_leading("./")
  end

  defp committed_in_head?(workspace_path, path) when is_binary(path) do
    normalized_path = normalize_relative_path(path)

    case System.cmd("git", ["cat-file", "-e", "HEAD:#{normalized_path}"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, true}

      {_output, 128} ->
        {:ok, false}

      {output, status} ->
        {:error, {:git_command_failed, ["cat-file", "-e", "HEAD:#{normalized_path}"], status, output}}
    end
  end
end
