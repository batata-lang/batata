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

  @type stage_name() :: atom()
  @type stage() :: map()
  @type receipt() :: map()

  @doc false
  @spec capture(MLIR.Context.t(), atom(), (MLIR.ActionTracing.Session.t() -> {term(), [stage()]})) ::
          {term(), receipt()}
  def capture(ctx, pipeline, callback) when is_atom(pipeline) and is_function(callback, 1) do
    started_at = monotonic_ns()
    session = MLIR.ActionTracing.attach(ctx, tags: @action_tags)

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
    result = callback.()
    duration_ns = elapsed_ns(started_at)
    events = MLIR.ActionTracing.drain(session)

    {result,
     %{
       "name" => Atom.to_string(name),
       "duration_ns" => duration_ns,
       "actions" => summarize_actions!(events)
     }}
  end

  defp summarize_actions!(events) do
    events
    |> pair_events!()
    |> Enum.group_by(&action_identity/1)
    |> Enum.map(fn {{tag, operation, description}, actions} ->
      durations = Enum.map(actions, & &1.duration_ns)

      %{
        "tag" => tag,
        "operation" => operation,
        "description" => description,
        "count" => length(actions),
        "duration_ns" => Enum.sum(durations),
        "max_duration_ns" => Enum.max(durations)
      }
    end)
    |> Enum.sort_by(&{&1["tag"], &1["operation"] || "", &1["description"] || ""})
  end

  defp pair_events!(events) do
    {pairs, open} = Enum.reduce(events, {[], %{}}, &pair_event!/2)

    if map_size(open) != 0 do
      raise ArgumentError, "native action trace contains unmatched before events"
    end

    Enum.reverse(pairs)
  end

  defp pair_event!(
         %{"phase" => "before", "tag" => tag, "depth" => depth, "t_ns" => started_at} = event,
         {pairs, open}
       )
       when is_integer(started_at) do
    key = {tag, depth}
    {pairs, Map.update(open, key, [event], &[event | &1])}
  end

  defp pair_event!(
         %{"phase" => "after", "tag" => tag, "depth" => depth, "t_ns" => stopped_at},
         {pairs, open}
       )
       when is_integer(stopped_at) do
    close_event!({tag, depth}, stopped_at, pairs, open)
  end

  defp pair_event!(malformed, _accumulator) do
    raise ArgumentError, "invalid native action trace event: #{inspect(malformed)}"
  end

  defp close_event!(key, stopped_at, pairs, open) do
    case Map.get(open, key, []) do
      [%{"t_ns" => started_at} = start | rest] ->
        pair = %{start: start, duration_ns: max(stopped_at - started_at, 0)}
        {[pair | pairs], update_open(open, key, rest)}

      [] ->
        raise ArgumentError, "native action trace contains an unmatched after event"
    end
  end

  defp update_open(open, key, []), do: Map.delete(open, key)
  defp update_open(open, key, rest), do: Map.put(open, key, rest)

  defp action_identity(%{start: start}) do
    {start["tag"], operation_name(start["ir_units"]), start["description"]}
  end

  defp operation_name([%{"kind" => "operation", "name" => name} | _]), do: name
  defp operation_name(_ir_units), do: nil

  defp monotonic_ns, do: System.monotonic_time(:nanosecond)
  defp elapsed_ns(started_at), do: max(monotonic_ns() - started_at, 0)
end
