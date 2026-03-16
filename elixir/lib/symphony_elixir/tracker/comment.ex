defmodule SymphonyElixir.Tracker.Comment do
  @moduledoc """
  Normalized tracker comment representation.
  """

  defstruct [
    :id,
    :issue_id,
    :body,
    :url,
    :author_id,
    :author_name,
    :created_at,
    :updated_at,
    tracker_meta: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          issue_id: String.t() | nil,
          body: String.t() | nil,
          url: String.t() | nil,
          author_id: String.t() | nil,
          author_name: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          tracker_meta: map()
        }
end
