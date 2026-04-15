defmodule SymphonyElixir.Kepler.Supervisor do
  @moduledoc """
  Supervisor for Kepler runtime services.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        SymphonyElixir.Kepler.Linear.Auth,
        SymphonyElixir.Kepler.ControlPlane
      ],
      strategy: :one_for_one
    )
  end
end
