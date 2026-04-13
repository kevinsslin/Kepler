defmodule SymphonyElixir.Kepler.Routing do
  @moduledoc """
  Repository routing for Kepler.
  """

  alias SymphonyElixir.Kepler.Config
  alias SymphonyElixir.Kepler.Linear.IssueContext

  @type routing_result ::
          {:resolved, map()}
          | {:ambiguous, [SymphonyElixir.Kepler.Config.Schema.Repository.t()], String.t()}

  @spec route_issue(IssueContext.t(), String.t(), module()) :: routing_result()
  def route_issue(%IssueContext{} = issue, agent_session_id, linear_client) when is_binary(agent_session_id) do
    repositories = Config.settings!().repositories

    case explicit_matches(repositories, issue) do
      [repository] ->
        {:resolved,
         %{
           repository: repository,
           source: "explicit_rule",
           reason: explicit_reason(repository, issue)
         }}

      [_ | _] = matches ->
        {:ambiguous, matches, "Multiple repositories matched explicit routing selectors."}

      [] ->
        route_by_suggestions(repositories, issue, agent_session_id, linear_client)
    end
  end

  @spec repository_candidates_for_elicitation([SymphonyElixir.Kepler.Config.Schema.Repository.t()]) ::
          [SymphonyElixir.Kepler.Config.Schema.Repository.t()]
  def repository_candidates_for_elicitation(repositories) when is_list(repositories) do
    limit = Config.settings!().routing.ambiguous_choice_limit
    Enum.take(repositories, limit)
  end

  @spec resolve_human_choice(
          String.t(),
          [SymphonyElixir.Kepler.Config.Schema.Repository.t()]
        ) :: {:ok, SymphonyElixir.Kepler.Config.Schema.Repository.t()} | :error
  def resolve_human_choice(choice, repositories) when is_binary(choice) and is_list(repositories) do
    normalized_choice = normalize_choice(choice)

    repositories
    |> Enum.find(fn repository ->
      normalize_choice(repository.id) == normalized_choice or
        normalize_choice(repository.full_name) == normalized_choice
    end)
    |> case do
      nil -> :error
      repository -> {:ok, repository}
    end
  end

  defp route_by_suggestions(repositories, issue, agent_session_id, linear_client) do
    candidates =
      Enum.map(repositories, fn repository ->
        %{
          hostname: "github.com",
          repositoryFullName: repository.full_name
        }
      end)

    case linear_client.suggest_repositories(issue.id, agent_session_id, candidates) do
      {:ok, [%{repository_full_name: full_name}]} ->
        case Enum.find(repositories, &(&1.full_name == full_name)) do
          nil ->
            {:ambiguous, repository_candidates_for_elicitation(repositories), "Linear did not return a registered repository."}

          repository ->
            {:resolved,
             %{
               repository: repository,
               source: "linear_suggestion",
               reason: "Linear issueRepositorySuggestions returned a single repository."
             }}
        end

      {:ok, suggestions} when is_list(suggestions) and suggestions != [] ->
        repositories_for_suggestions =
          suggestions
          |> Enum.map(& &1.repository_full_name)
          |> Enum.uniq()
          |> Enum.map(fn full_name -> Enum.find(repositories, &(&1.full_name == full_name)) end)
          |> Enum.reject(&is_nil/1)

        {:ambiguous, repository_candidates_for_elicitation(repositories_for_suggestions), "Linear returned multiple repository suggestions."}

      _ ->
        {:ambiguous, repository_candidates_for_elicitation(repositories), "No unique repository match was found."}
    end
  end

  defp explicit_matches(repositories, issue) do
    Enum.filter(repositories, &explicit_match?(&1, issue))
  end

  defp explicit_match?(repository, %IssueContext{} = issue) do
    label_match?(repository.labels, issue.labels) or
      selector_match?(repository.team_keys, issue.team_key) or
      selector_match?(repository.project_ids, issue.project_id) or
      selector_match?(repository.project_slugs, issue.project_slug)
  end

  defp label_match?(selectors, labels) when is_list(selectors) and is_list(labels) do
    normalized_labels = MapSet.new(Enum.map(labels, &normalize_choice/1))

    selectors
    |> Enum.map(&normalize_choice/1)
    |> Enum.any?(&MapSet.member?(normalized_labels, &1))
  end

  defp selector_match?(selectors, value) when is_list(selectors) and is_binary(value) do
    normalized_value = normalize_choice(value)
    Enum.any?(selectors, &(normalize_choice(&1) == normalized_value))
  end

  defp selector_match?(_selectors, _value), do: false

  defp explicit_reason(repository, issue) do
    cond do
      label_match?(repository.labels, issue.labels) ->
        "Matched repository labels against Linear issue labels."

      selector_match?(repository.team_keys, issue.team_key) ->
        "Matched repository team selector against Linear issue team."

      selector_match?(repository.project_ids, issue.project_id) ->
        "Matched repository project id selector against Linear issue project."

      selector_match?(repository.project_slugs, issue.project_slug) ->
        "Matched repository project slug selector against Linear issue project."

      true ->
        "Matched explicit routing selectors."
    end
  end

  defp normalize_choice(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
