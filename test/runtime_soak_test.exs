defmodule Batata.RuntimeSoakTest do
  # MLIR compilation is CPU-heavy and process-global LLVM resources are not a
  # useful thing to oversubscribe with the rest of the async suite. The test
  # itself still submits two concurrent sessions. Their engine lifetimes are
  # serialized because MLIR resolves same-named C wrappers process-globally;
  # the deterministic native runtime soak separately covers worker fan-in.
  use ExUnit.Case, async: false

  alias Beaver.MLIR

  @moduletag timeout: 180_000

  @fan_in_source """
  defmodule FanIn do
    def main() do
      me = self()
      spawn(fn -> send(me, 10) end)
      spawn(fn -> send(me, 20) end)
      sum = Enum.reduce([1, 2, 3, 4, 5], 0, fn x, acc -> x + acc end)

      first = receive do
        10 -> 10
      end

      second = receive do
        20 -> 20
      end

      sum + first + second
    end
  end
  """

  defp run_session(index, source, opts) do
    started = System.monotonic_time(:microsecond)
    ctx = MLIR.Context.create()
    created = elapsed_us(started)

    outcome =
      try do
        value = Batata.execute(source, ctx, opts)
        {:passed, inspect(value, limit: :infinity), nil, nil}
      rescue
        error ->
          {:error, nil, inspect(error.__struct__),
           Exception.format(:error, error, __STACKTRACE__)}
      end

    completed = elapsed_us(started)
    MLIR.Context.destroy(ctx)
    destroyed = elapsed_us(started)

    %{
      "session" => index,
      "status" => outcome |> elem(0) |> to_string(),
      "actual" => elem(outcome, 1),
      "error_type" => elem(outcome, 2),
      "diagnostic" => elem(outcome, 3),
      "timeline" => [
        %{"event" => "context_created", "offset_us" => created},
        %{"event" => "execution_completed", "offset_us" => completed},
        %{"event" => "context_destroyed", "offset_us" => destroyed}
      ]
    }
  end

  defp write_artifact(identity, source, config, expected, records) do
    stable = %{
      "test_identity" => identity,
      "source_sha256" => digest(source),
      "seed" => ExUnit.configuration()[:seed],
      "config" => Map.new(config, fn {key, value} -> {to_string(key), value} end),
      "expected" => inspect(expected, limit: :infinity, charlists: :as_lists),
      "outcomes" =>
        Enum.map(records, &Map.take(&1, ["session", "status", "actual", "error_type"]))
    }

    artifact =
      stable
      |> Map.put("schema_version", 1)
      |> Map.put("artifact_fingerprint", stable |> JSON.encode!() |> digest())
      |> Map.put("sessions", records)

    directory = System.get_env("BATATA_RUNTIME_ARTIFACT_DIR", "_build/runtime_soak")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, identity <> ".json"), JSON.encode!(artifact))
  end

  defp elapsed_us(started), do: System.monotonic_time(:microsecond) - started
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  test "concurrent JIT submissions keep actor results runtime-local" do
    opts = [workers: 1, process_cap: 2, reduction_budget: 2]

    records =
      1..2
      |> Task.async_stream(
        &run_session(&1, @fan_in_source, opts),
        max_concurrency: 2,
        timeout: 180_000
      )
      |> Enum.map(fn {:ok, record} -> record end)

    write_artifact("concurrent-fan-in", @fan_in_source, opts, [45, 45], records)

    assert Enum.map(records, & &1["status"]) == ["passed", "passed"]
    assert Enum.map(records, & &1["actual"]) == ["45", "45"]
  end

  test "concurrent composite results stay bound to their creating engine" do
    source = """
    defmodule CompositeSession do
      def main(), do: {1, [2, 3], %{7 => 42}, <<4, 5>>}
    end
    """

    records =
      1..8
      |> Task.async_stream(
        &run_session(&1, source, []),
        max_concurrency: 4,
        timeout: 180_000
      )
      |> Enum.map(fn {:ok, record} -> record end)

    expected = List.duplicate({1, [2, 3], %{7 => 42}, <<4, 5>>}, 8)
    write_artifact("concurrent-composite", source, [], expected, records)

    assert Enum.map(records, & &1["status"]) == List.duplicate("passed", 8)
    assert Enum.map(records, & &1["actual"]) == Enum.map(expected, &inspect/1)
  end
end
