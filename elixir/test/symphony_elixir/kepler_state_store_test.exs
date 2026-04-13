defmodule SymphonyElixir.KeplerStateStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Kepler.Run
  alias SymphonyElixir.Kepler.StateStore

  test "decode_run ignores unknown keys in persisted state" do
    run =
      StateStore.decode_run(%{
        "id" => "run-1",
        "linear_issue_id" => "issue-1",
        "linear_agent_session_id" => "session-1",
        "status" => "queued",
        "future_field" => "ignored"
      })

    assert %Run{} = run
    assert run.id == "run-1"
    assert run.linear_issue_id == "issue-1"
    assert run.linear_agent_session_id == "session-1"
    assert run.status == "queued"
    refute Map.has_key?(Map.from_struct(run), :future_field)
  end

  test "new run ids are unique across fresh BEAM processes" do
    run_id_1 = fresh_process_run_id()
    run_id_2 = fresh_process_run_id()

    assert String.starts_with?(run_id_1, "run-")
    assert String.starts_with?(run_id_2, "run-")
    assert run_id_1 != run_id_2
  end

  defp fresh_process_run_id do
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&String.contains?(&1, "/_build/test/"))

    args =
      Enum.flat_map(code_paths, &["-pa", &1]) ++
        ["-e", "IO.write(SymphonyElixir.Kepler.Run.new(%{}).id)"]

    {output, 0} = System.cmd(elixir, args)
    output
  end
end
