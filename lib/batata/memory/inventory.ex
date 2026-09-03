defmodule Batata.Memory.Inventory do
  @moduledoc """
  Fail-closed allocation summaries for Batata IR and native call boundaries.

  The registry records facts that are known today. Every absent or future
  entry is represented as `:unknown`; it is never silently interpreted as
  `:none`.
  """

  alias Batata.Native.Provider
  alias Batata.Stdlib.Plan, as: StdlibPlan

  defmodule Entry do
    @moduledoc "One allocation-inventory fact before it is attached to a program site."

    @enforce_keys [:kind, :subject, :classification, :provenance]
    defstruct [:kind, :subject, :classification, :provenance, context: %{}]

    @type t :: %__MODULE__{
            kind: :intrinsic | :stdlib | :provider | :external,
            subject: String.t(),
            classification: :none | :may_allocate | :unknown,
            provenance: String.t(),
            context: map()
          }
  end

  @may_allocate_intrinsics MapSet.new(~w(
    ex.binary
    ex.binary_decode16
    ex.binary_encode16
    ex.binary_from_list
    ex.binary_part
    ex.binary_quote
    ex.binary_slice
    ex.enumerable_intersperse
    ex.enumerable_into_map
    ex.enumerable_to_list
    ex.enumerable_to_list_range
    ex.file_read
    ex.file_read_lines
    ex.float_lit
    ex.float_to_binary_short
    ex.int_to_hex
    ex.int_to_string
    ex.int_to_string_base
    ex.integer_add
    ex.integer_div
    ex.integer_mul
    ex.integer_rem
    ex.integer_sub
    ex.iodata_to_binary
    ex.list
    ex.list_cons
    ex.list_flatten
    ex.list_insert_at
    ex.make_fun
    ex.make_fun_with_arity
    ex.make_fun_with_signature
    ex.map
    ex.map_put
    ex.mapset_from_list
    ex.mapset_put
    ex.process_table_reset
    ex.result_create
    ex.runtime_create
    ex.spawn
    ex.stream_drop
    ex.stream_filter
    ex.stream_take
    ex.string_to_float
    ex.term_export
    ex.term_import
    ex.try
    ex.tuple
  ))

  @non_allocating_intrinsics MapSet.new(~w(
    ex.add
    ex.binary_get
    ex.binary_length
    ex.binary_utf8_get
    ex.binary_utf8_length
    ex.binary_utf8_width
    ex.box
    ex.catch_value
    ex.clock_init
    ex.cmp
    ex.cont_active
    ex.cont_clear
    ex.cont_load_acc
    ex.cont_load_arg
    ex.cont_load_cursor
    ex.cont_pending
    ex.current_entry
    ex.div
    ex.exported_clone
    ex.exported_destroy
    ex.exported_get
    ex.exported_length
    ex.fun_arity
    ex.fun_result_mode
    ex.func
    ex.func_addr
    ex.if
    ex.is_atom
    ex.is_binary
    ex.is_float
    ex.is_integer
    ex.is_list
    ex.is_map
    ex.is_tuple
    ex.list_get
    ex.list_head
    ex.list_length
    ex.list_tail
    ex.lit
    ex.mailbox_clear
    ex.mailbox_len
    ex.mailbox_peek
    ex.mailbox_remove
    ex.map_fetch
    ex.map_length
    ex.mapset_member
    ex.monotonic_time
    ex.mul
    ex.native_time
    ex.nil_word
    ex.process_done
    ex.process_dictionary_put
    ex.process_exit
    ex.process_exit_reason
    ex.process_result
    ex.process_trap_exit
    ex.process_wait
    ex.processes_runnable
    ex.raise
    ex.receive
    ex.receive_start
    ex.receive_start_set
    ex.reduction_tick
    ex.rem
    ex.result_destroy
    ex.result_exception_kind
    ex.result_exception_reason
    ex.result_root_kind
    ex.result_root_word
    ex.result_atom_name
    ex.result_term_get
    ex.result_term_kind
    ex.result_term_length
    ex.return
    ex.runtime_destroy
    ex.runtime_enter
    ex.runtime_leave
    ex.schedule_next
    ex.self
    ex.send
    ex.string_printable
    ex.string_to_atom
    ex.string_to_existing_atom
    ex.string_to_int
    ex.sub
    ex.term_eq
    ex.term_eq_loose
    ex.integer_compare
    ex.term_handle_destroy
    ex.term_handle_export
    ex.throw
    ex.to_int
    ex.to_word
    ex.tuple_get
    ex.tuple_length
    ex.unbox
    ex.unique_integer
    ex.var
    ex.worker_run
    ex.yield
    ex.yield_mark
  ))

  # These operations are part of the pinned `ex` dialect, but M0 deliberately
  # has no closed allocation fact for them. Listing them separately makes the
  # known-unknown boundary auditable while keeping future dialect operations
  # distinguishable from reviewed gaps.
  @unknown_intrinsics MapSet.new(~w(
    ex.apply
    ex.bind
    ex.call
    ex.case
    ex.clause
    ex.cont_save
    ex.demonitor
    ex.enumerable_count
    ex.enumerable_flat_map_term_fun
    ex.enumerable_map_fun
    ex.enumerable_map_term_fun
    ex.enumerable_map_term_fun_c
    ex.enumerable_reduce
    ex.enumerable_reduce_c
    ex.enumerable_reduce_fun
    ex.enumerable_reduce_range
    ex.exit
    ex.link
    ex.monitor
    ex.receive_cont_save
    ex.unlink
  ))

  if not MapSet.disjoint?(@may_allocate_intrinsics, @non_allocating_intrinsics) or
       not MapSet.disjoint?(@may_allocate_intrinsics, @unknown_intrinsics) or
       not MapSet.disjoint?(@non_allocating_intrinsics, @unknown_intrinsics) do
    raise "memory intrinsic allocation registry contains conflicting entries"
  end

  @doc "Returns the explicit allocation fact for an `ex.*` operation name."
  @spec intrinsic(String.t()) :: Entry.t()
  def intrinsic(name) when is_binary(name) do
    cond do
      MapSet.member?(@may_allocate_intrinsics, name) ->
        entry(:intrinsic, name, :may_allocate, "batata.memory.intrinsic/1")

      MapSet.member?(@non_allocating_intrinsics, name) ->
        entry(:intrinsic, name, :none, "batata.memory.intrinsic/1")

      MapSet.member?(@unknown_intrinsics, name) ->
        entry(:intrinsic, name, :unknown, "batata.memory.intrinsic.unknown")

      true ->
        entry(:intrinsic, name, :unknown, "batata.memory.intrinsic.missing")
    end
  end

  @doc "Returns the allocation fact declared by the built-in stdlib registry."
  @spec stdlib({module(), atom(), non_neg_integer()}) :: Entry.t()
  def stdlib({module, function, arity} = mfa) do
    subject = Exception.format_mfa(module, function, arity)

    case Batata.Stdlib.plan(mfa) do
      %StdlibPlan{} = plan -> plan_entry(:stdlib, subject, plan, "batata.stdlib.plan/1")
      nil -> entry(:stdlib, subject, :unknown, "batata.stdlib.missing")
    end
  end

  @doc "Returns the allocation fact supplied by a project-local native provider."
  @spec provider(term()) :: Entry.t()
  def provider(node) do
    subject = node |> then(&struct_name/1) |> inspect()

    case Provider.native_plan(node) do
      %StdlibPlan{} = plan -> plan_entry(:provider, subject, plan, "batata.native.provider")
      nil -> entry(:provider, subject, :unknown, "batata.native.provider.missing")
    end
  end

  @doc "Classifies an unresolved host, NIF, callback, or external callee."
  @spec external(String.t()) :: Entry.t()
  def external(callee) when is_binary(callee) and callee != "" do
    entry(:external, callee, :unknown, "batata.external.summary.missing")
  end

  @doc "Returns every pinned `ex` operation with an explicit inventory entry."
  @spec known_intrinsics() :: [String.t()]
  def known_intrinsics do
    @may_allocate_intrinsics
    |> MapSet.union(@non_allocating_intrinsics)
    |> MapSet.union(@unknown_intrinsics)
    |> Enum.sort()
  end

  defp plan_entry(kind, subject, plan, provenance) do
    entry(kind, subject, normalize_allocation(plan.allocation), provenance, %{
      "class" => to_string(plan.class),
      "mfa" => inspect(plan.mfa)
    })
  end

  defp normalize_allocation(allocation) when allocation in [:none, :may_allocate, :unknown],
    do: allocation

  defp normalize_allocation(_allocation), do: :unknown

  defp entry(kind, subject, classification, provenance, context \\ %{}) do
    %Entry{
      kind: kind,
      subject: subject,
      classification: classification,
      provenance: provenance,
      context: context
    }
  end

  defp struct_name(%module{}), do: module
  defp struct_name(_node), do: :untyped
end
