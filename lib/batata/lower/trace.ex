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

  defmodule Session do
    @moduledoc false
    @enforce_keys [:native, :owner, :ref]
    defstruct [:native, :owner, :ref]

    @type t() :: %__MODULE__{native: term(), owner: pid(), ref: reference()}
  end

  @doc false
  @spec capture(MLIR.Context.t(), atom(), (Session.t() -> {term(), [stage()]})) ::
          {term(), receipt()}
  def capture(ctx, pipeline, callback) when is_atom(pipeline) and is_function(callback, 1) do
    case capture_result(ctx, pipeline, callback) do
      {{:ok, result}, receipt} ->
        {result, receipt}

      {{:error, kind, reason, stacktrace}, _receipt} ->
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc false
  @spec capture_result(
          MLIR.Context.t(),
          atom(),
          (Session.t() -> {term(), [stage()]})
        ) ::
          {{:ok, term()} | {:error, atom(), term(), list()}, receipt()}
  @spec capture_result(
          MLIR.Context.t(),
          atom(),
          (Session.t() -> {term(), [stage()]}),
          keyword()
        ) ::
          {{:ok, term()} | {:error, atom(), term(), list()}, receipt()}
  def capture_result(ctx, pipeline, callback, opts \\ [])
      when is_atom(pipeline) and is_function(callback, 1) do
    started_at = monotonic_ns()

    native =
      if Keyword.get(opts, :actions, true) do
        MLIR.ActionTracing.attach(ctx,
          tags: @action_tags,
          telemetry: fn _event, _measurements, _metadata -> :ok end
        )
      end

    session = %Session{native: native, owner: self(), ref: make_ref()}

    try do
      outcome =
        try do
          {result, _stages} = callback.(session)
          {:ok, result}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end

      receipt = %{
        "schema_version" => @schema_version,
        "pipeline" => Atom.to_string(pipeline),
        "duration_ns" => elapsed_ns(started_at),
        "status" => outcome_status(outcome),
        "stages" => collect_stages(session.ref)
      }

      {outcome, receipt}
    after
      if native, do: MLIR.ActionTracing.detach(native)
    end
  end

  @doc false
  @spec stage(Session.t(), stage_name(), (-> term())) :: {term(), stage()}
  def stage(%Session{} = session, name, callback)
      when is_atom(name) and is_function(callback, 0) do
    stage_with_details(session, name, fn -> {callback.(), %{}} end)
  end

  @doc false
  @spec stage_with_details(Session.t(), stage_name(), (-> {term(), map()})) :: {term(), stage()}
  def stage_with_details(%Session{} = session, name, callback)
      when is_atom(name) and is_function(callback, 0) do
    started_at = monotonic_ns()

    drainer =
      if session.native,
        do: Task.async(fn -> drain_loop(session.native, empty_accumulator()) end)

    outcome =
      try do
        {result, details} = callback.()
        {:ok, result, details}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    duration_ns = elapsed_ns(started_at)

    action_outcome =
      if drainer do
        send(drainer.pid, :finish)

        try do
          {:ok, Task.await(drainer, 30_000)}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end
      else
        {:ok, []}
      end

    stage =
      %{
        "name" => Atom.to_string(name),
        "duration_ns" => duration_ns,
        "status" => stage_status(outcome, action_outcome),
        "actions" => actions(action_outcome)
      }
      |> Map.merge(stage_details(outcome))
      |> maybe_put_action_trace_failure(action_outcome)

    send(session.owner, {:batata_lower_stage, session.ref, stage})

    case {outcome, action_outcome} do
      {{:ok, result, _details}, {:ok, _actions}} ->
        {result, stage}

      {{:error, kind, reason, stacktrace}, _action_outcome} ->
        :erlang.raise(kind, reason, stacktrace)

      {{:ok, _result, _details}, {:error, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp collect_stages(ref, stages \\ []) do
    receive do
      {:batata_lower_stage, ^ref, stage} -> collect_stages(ref, [stage | stages])
    after
      0 -> Enum.reverse(stages)
    end
  end

  defp outcome_status({:ok, _result}), do: "ok"
  defp outcome_status({:error, _kind, _reason, _stacktrace}), do: "error"

  defp stage_status({:ok, _result, _details}, {:ok, _actions}), do: "ok"
  defp stage_status(_outcome, _action_outcome), do: "error"

  defp actions({:ok, actions}), do: actions
  defp actions({:error, _kind, _reason, _stacktrace}), do: []

  defp stage_details({:ok, _result, details}) when is_map(details), do: details
  defp stage_details(_outcome), do: %{}

  defp maybe_put_action_trace_failure(stage, {:ok, _actions}), do: stage

  defp maybe_put_action_trace_failure(stage, {:error, kind, reason, _stacktrace}) do
    Map.put(stage, "action_trace_failure", %{
      "kind" => Atom.to_string(kind),
      "reason" => reason |> inspect(limit: 20, printable_limit: 256) |> String.slice(0, 512)
    })
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
