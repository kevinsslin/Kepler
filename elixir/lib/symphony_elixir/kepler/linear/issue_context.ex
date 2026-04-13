defmodule SymphonyElixir.Kepler.Linear.IssueContext do
  @moduledoc """
  Normalized Linear issue context used by Kepler routing and execution.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          branch_name: String.t() | nil,
          labels: [String.t()],
          team_key: String.t() | nil,
          project_id: String.t() | nil,
          project_slug: String.t() | nil
        }

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :url,
    :branch_name,
    labels: [],
    team_key: nil,
    project_id: nil,
    project_slug: nil
  ]
end
