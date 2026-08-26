defmodule Batata.Lower.Trace do
  @moduledoc """
  Builds machine-readable receipts for traced `ex` lowering runs.

  A trace is opt-in and context scoped. It combines Batata's pipeline stage
  envelopes with Beaver's native MLIR action events, then reduces those events
  to bounded summaries instead of retaining the raw event stream.
  """

  alias Beaver.MLIR

  @schema_version 1
  @action_tags ["apply-conversion", "apply-pattern", "pass-execution"]
  @drain_interval_ms 250

  @type stage_name() :: atom()
  @type stage() :: map()
  @type receipt() :: map()

  @doc false
  @spec capture(MLIR.Context.t(), atom(), (MLIR.ActionTracing.Session.t() -> {term(), [stage()]})) ::
          {term(), receipt()}
  def capture(ctx, pipeline, callback) when is_atom(pipeline) and is_function(callback, 1) do
    started_at = monotonic_ns()

    session =
      MLIR.ActionTracing.attach(ctx,
        tags: @action_tags,
        telemetry: fn _event, _measurements, _metadata -> :ok end
      )

    try do
      {result, stages} = callback.(session)

      receipt = %{
        "schema_version" => @schema_version,
        "pipeline" => Atom.to_string(pipeline),
        "duration_ns" => elapsed_ns(started_at),
        "stages" => stages
      }

      {result, receipt}
    after
      MLIR.ActionTracing.detach(session)
    end
  end

  @doc false
  @spec stage(MLIR.ActionTracing.Session.t(), stage_name(), (-> term())) :: {term(), stage()}
  def stage(session, name, callback) when is_atom(name) and is_function(callback, 0) do
    started_at = monotonic_ns()
    drainer = Task.async(fn -> drain_loop(session, empty_accumulator()) end)

    try do
      result = callback.()
      duration_ns = elapsed_ns(started_at)
      send(drainer.pid, :finish)
      actions = Task.await(drainer, 30_000)

      {result,
       %{
         "name" => Atom.to_string(name),
         "duration_ns" => duration_ns,
         "actions" => actions
       }}
    catch
      kind, reason ->
        Task.shutdown(drainer, :brutal_kill)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp drain_loop(session, accumulator) do
    receive do
      :finish ->
        session
        |> MLIR.ActionTracing.drain()
        |> accumulate(accumulator)
        |> finish_accumulator!()
    after
      @drain_interval_ms ->
        accumulator =
          session
          |> MLIR.ActionTracing.drain()
          |> accumulate(accumulator)

        drain_loop(session, accumulator)
    end
  end

  defp empty_accumulator, do: %{open: %{}, summaries: %{}}

  defp accumulate(events, accumulator) do
    Enum.reduce(events, accumulator, &accumulate_event!/2)
  end

  defp finish_accumulator!(%{open: open, summaries: summaries}) do
    if map_size(open) != 0 do
      raise ArgumentError, "native action trace contains unmatched before events"
    end

    summaries
    |> Map.values()
    |> Enum.sort_by(&{&1["tag"], &1["operation"] || "", &1["description"] || ""})
  end

  defp accumulate_event!(
         %{"phase" => "before", "tag" => tag, "depth" => depth, "t_ns" => started_at} = event,
         %{open: open} = accumulator
       )
       when is_integer(started_at) do
    key = {tag, depth}
    %{accumulator | open: Map.update(open, key, [event], &[event | &1])}
  end

  defp accumulate_event!(
         %{"phase" => "after", "tag" => tag, "depth" => depth, "t_ns" => stopped_at},
         accumulator
       )
       when is_integer(stopped_at) do
    close_event!({tag, depth}, stopped_at, accumulator)
  end

  defp accumulate_event!(malformed, _accumulator) do
    raise ArgumentError, "invalid native action trace event: #{inspect(malformed)}"
  end

  defp close_event!(key, stopped_at, %{open: open, summaries: summaries} = accumulator) do
    case Map.get(open, key, []) do
      [%{"t_ns" => started_at} = start | rest] ->
        duration_ns = max(stopped_at - started_at, 0)
        identity = action_identity(start)

        %{
          accumulator
          | open: update_open(open, key, rest),
            summaries: update_summary(summaries, identity, duration_ns)
        }

      [] ->
        raise ArgumentError, "native action trace contains an unmatched after event"
    end
  end

  defp update_open(open, key, []), do: Map.delete(open, key)
  defp update_open(open, key, rest), do: Map.put(open, key, rest)

  defp action_identity(start) do
    {start["tag"], operation_name(start["ir_units"]), start["description"]}
  end

  defp update_summary(summaries, {tag, operation, description} = identity, duration_ns) do
    Map.update(
      summaries,
      identity,
      %{
        "tag" => tag,
        "operation" => operation,
        "description" => description,
        "count" => 1,
        "duration_ns" => duration_ns,
        "max_duration_ns" => duration_ns
      },
      fn summary ->
        %{
          summary
          | "count" => summary["count"] + 1,
            "duration_ns" => summary["duration_ns"] + duration_ns,
            "max_duration_ns" => max(summary["max_duration_ns"], duration_ns)
        }
      end
    )
  end

  defp operation_name([%{"kind" => "operation", "name" => name} | _]), do: name
  defp operation_name(_ir_units), do: nil

  defp monotonic_ns, do: System.monotonic_time(:nanosecond)
  defp elapsed_ns(started_at), do: max(monotonic_ns() - started_at, 0)
end
