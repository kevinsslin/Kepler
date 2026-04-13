defmodule SymphonyElixir.RuntimeMode do
  @moduledoc """
  Tracks whether Symphony is running in classic workflow mode or Kepler control-plane mode.
  """

  @type t :: :workflow | :kepler

  @spec current() :: t()
  def current do
    case Application.get_env(:symphony_elixir, :runtime_mode, :workflow) do
      :kepler -> :kepler
      "kepler" -> :kepler
      _ -> :workflow
    end
  end

  @spec workflow?() :: boolean()
  def workflow?, do: current() == :workflow

  @spec kepler?() :: boolean()
  def kepler?, do: current() == :kepler

  @spec set(t()) :: :ok
  def set(mode) when mode in [:workflow, :kepler] do
    Application.put_env(:symphony_elixir, :runtime_mode, mode)
    :ok
  end
end
