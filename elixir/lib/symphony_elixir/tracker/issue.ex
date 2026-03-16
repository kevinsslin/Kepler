defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized issue representation used by the orchestrator across trackers.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :semantic_state,
    :branch_name,
    :url,
    :assignee_id,
    :assignee_ref,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil,
    tracker_meta: %{}
  ]

  @type blocker_ref :: %{
          optional(:id) => String.t() | nil,
          optional(:identifier) => String.t() | nil,
          optional(:state) => String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          semantic_state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          assignee_ref: map() | nil,
          blocked_by: [blocker_ref()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          tracker_meta: map()
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
