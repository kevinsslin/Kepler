defmodule SymphonyElixir.Kepler.StateStore do
  @moduledoc """
  Persists Kepler run state to a JSON file on the attached volume.
  """

  alias SymphonyElixir.Kepler.Config.Schema
  alias SymphonyElixir.Kepler.Run

  @type state_payload :: map()

  @spec load(Schema.t()) :: {:ok, state_payload()} | {:error, term()}
  def load(settings) do
    path = Schema.state_file_path(settings)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"runs" => _runs} = payload} ->
            {:ok, payload}

          {:ok, _payload} ->
            {:error, :invalid_kepler_state_payload}

          {:error, reason} ->
            {:error, {:kepler_state_decode_failed, reason}}
        end

      {:error, :enoent} ->
        {:ok, empty_payload()}

      {:error, reason} ->
        {:error, {:kepler_state_read_failed, path, reason}}
    end
  end

  @spec save(Schema.t(), state_payload()) :: :ok | {:error, term()}
  def save(settings, %{"runs" => _runs} = payload) do
    root = settings.state.root
    path = Schema.state_file_path(settings)
    temp_path = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(root),
         {:ok, encoded} <- Jason.encode(payload, pretty: true),
         :ok <- File.write(temp_path, encoded),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp_path)
        {:error, {:kepler_state_write_failed, path, reason}}
    end
  end

  @spec empty_payload() :: state_payload()
  def empty_payload do
    %{
      "runs" => [],
      "queued_run_ids" => [],
      "active_run_ids" => []
    }
  end

  @spec decode_runs(state_payload()) :: %{String.t() => Run.t()}
  def decode_runs(%{"runs" => runs}) when is_list(runs) do
    runs
    |> Enum.reduce(%{}, fn run_map, acc ->
      run = decode_run(run_map)
      Map.put(acc, run.id, run)
    end)
  end

  @spec encode_runs(%{String.t() => Run.t()}) :: [map()]
  def encode_runs(runs) when is_map(runs) do
    runs
    |> Map.values()
    |> Enum.map(&Map.from_struct/1)
  end

  @spec decode_run(map()) :: Run.t()
  def decode_run(run_map) when is_map(run_map) do
    allowed_keys = Run.__struct__() |> Map.keys() |> MapSet.new()
    allowed_string_keys = Enum.into(allowed_keys, %{}, fn key -> {Atom.to_string(key), key} end)

    atomized =
      Enum.reduce(run_map, %{}, fn {key, value}, acc ->
        case decode_key(key, allowed_keys, allowed_string_keys) do
          nil -> acc
          atom_key -> Map.put(acc, atom_key, value)
        end
      end)

    struct!(Run, atomized)
  end

  defp decode_key(key, allowed_keys, _allowed_string_keys) when is_atom(key) do
    if MapSet.member?(allowed_keys, key), do: key, else: nil
  end

  defp decode_key(key, _allowed_keys, allowed_string_keys) when is_binary(key) do
    Map.get(allowed_string_keys, key)
  end
end
