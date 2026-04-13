defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.RuntimeMode

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor}
      ] ++ runtime_children(RuntimeMode.current())

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    if RuntimeMode.workflow?() do
      SymphonyElixir.StatusDashboard.render_offline_status()
    end

    :ok
  end

  @type runtime_child :: Supervisor.child_spec() | {module(), term()} | module()

  @spec runtime_children(SymphonyElixir.RuntimeMode.t()) :: [runtime_child()]
  defp runtime_children(:kepler) do
    [
      SymphonyElixir.Kepler.Supervisor,
      SymphonyElixir.HttpServer
    ]
  end

  defp runtime_children(:workflow) do
    [
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]
  end
end
