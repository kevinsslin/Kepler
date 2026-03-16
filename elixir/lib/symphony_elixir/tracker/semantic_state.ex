defmodule SymphonyElixir.Tracker.SemanticState do
  @moduledoc """
  Helpers for tracker-agnostic issue routing states.
  """

  @states ~w(backlog queued active review merge rework terminal)

  @spec all() :: [String.t()]
  def all, do: @states

  @spec dispatchable() :: [String.t()]
  def dispatchable, do: ~w(queued active merge rework)

  @spec hold() :: [String.t()]
  def hold, do: ~w(backlog review)

  @spec terminal?(term()) :: boolean()
  def terminal?(state), do: normalize(state) == "terminal"

  @spec normalize(term()) :: String.t() | nil
  def normalize(state) when is_binary(state) do
    case state |> String.trim() |> String.downcase() do
      "" -> nil
      normalized when normalized in @states -> normalized
      _ -> nil
    end
  end

  def normalize(_state), do: nil
end
