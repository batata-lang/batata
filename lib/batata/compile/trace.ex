defmodule Batata.Compile.Trace do
  @moduledoc false

  alias Beaver.MLIR

  @schema_version 1

  defmodule Session do
    @moduledoc false
    @enforce_keys [:owner, :ref]
    defstruct [:owner, :ref]
  end

  @spec capture_result((Session.t() -> term())) ::
          {{:ok, term()} | {:error, atom(), term(), list()}, map()}
  def capture_result(callback) when is_function(callback, 1) do
    started = measurement_start()
    session = %Session{owner: self(), ref: make_ref()}

    outcome =
      try do
        {:ok, callback.(session)}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    receipt =
      started
      |> measurement_finish(outcome_status(outcome), "frontend_to_ex")
      |> Map.merge(%{
        "schema_version" => @schema_version,
        "pipeline" => "frontend_to_ex",
        "stages" => collect_stages(session.ref)
      })

    {outcome, receipt}
  end

  @spec stage(Session.t(), atom(), (-> term())) :: term()
  def stage(%Session{} = session, name, callback)
      when is_atom(name) and is_function(callback, 0) do
    started = measurement_start()

    outcome =
      try do
        {:ok, callback.()}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    send(
      session.owner,
      {:batata_compile_stage, session.ref,
       measurement_finish(started, outcome_status(outcome), Atom.to_string(name))}
    )

    case outcome do
      {:ok, result} -> result
      {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp collect_stages(ref, stages \\ []) do
    receive do
      {:batata_compile_stage, ^ref, stage} -> collect_stages(ref, [stage | stages])
    after
      0 -> Enum.reverse(stages)
    end
  end

  defp measurement_start do
    %{
      monotonic_ns: System.monotonic_time(:nanosecond),
      process_cpu_time_ns: MLIR.CAPI.beaver_raw_process_cpu_time(),
      peak_rss_bytes: MLIR.CAPI.beaver_raw_peak_rss(),
      reductions: reductions(),
      process_memory_bytes: process_memory_bytes()
    }
  end

  defp measurement_finish(started, status, name) do
    process_memory_after_bytes = process_memory_bytes()
    peak_rss_after_bytes = MLIR.CAPI.beaver_raw_peak_rss()

    %{
      "name" => name,
      "status" => status,
      "duration_ns" => max(System.monotonic_time(:nanosecond) - started.monotonic_ns, 0),
      "process_cpu_time_ns" =>
        max(MLIR.CAPI.beaver_raw_process_cpu_time() - started.process_cpu_time_ns, 0),
      "rss" => %{
        "peak_before_bytes" => started.peak_rss_bytes,
        "peak_after_bytes" => peak_rss_after_bytes,
        "peak_delta_bytes" => max(peak_rss_after_bytes - started.peak_rss_bytes, 0)
      },
      "beam" => %{
        "reductions" => max(reductions() - started.reductions, 0),
        "process_memory_before_bytes" => started.process_memory_bytes,
        "process_memory_after_bytes" => process_memory_after_bytes
      }
    }
  end

  defp outcome_status({:ok, _result}), do: "ok"
  defp outcome_status({:error, _kind, _reason, _stacktrace}), do: "error"

  defp reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end

  defp process_memory_bytes do
    {:memory, memory} = Process.info(self(), :memory)
    memory
  end
end
