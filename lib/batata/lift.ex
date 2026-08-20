defmodule Batata.Lift do
  @moduledoc """
  Lifts a `Batata.Frontend` module snapshot into `ex` dialect IR.

  The scalar slice supports integer literals, `+`/`-`/`*`, `=` bindings, local
  calls, comparisons (`==`/`!=`/`<`/`<=`/`>`/`>=`), `case` with integer literal
  or catch-all patterns and optional guards, and functions with integer
  parameters. Multi-clause functions (single argument) dispatch on the
  argument with `ex.case`; the final clause must be a catch-all. The term
  slice adds tuple, list, map and binary literals plus the `Kernel` term
  predicates, and tail-recursive binary scanners (fixed-width head segments +
  rest, `± delta` accumulator) compile to `scf.while` cursor loops instead of
  recursion.
  (`is_atom`/`is_binary`/`is_list`/`is_tuple`/`is_map`/`is_integer`); they
  lift to the `ex.tuple`/`ex.list`/`ex.map`/`ex.binary`/`ex.is_*` ops and are
  lowered through the Zig term runtime ABI. Bindings lower directly to SSA:
  `ex.var`/`ex.bind` are term-universe bookkeeping and stay out of the typed
  scalar slice (they are erased by
  `Beaver.MLIR.Dialect.Ex.MaterializeBoundVariables` on the term path). Anything
  outside the slice raises `Batata.Lift.Error` explicitly instead of being
  silently dropped.
  """

  alias Batata.Frontend
  alias Batata.Frontend.GuardSupport
  alias Batata.Symbol
  alias Batata.Transform.PatternPlan
  alias Beaver.MLIR
  alias Beaver.MLIR.Dialect.Ex
  alias Beaver.Walker

  @known_atoms_key {__MODULE__, :known_atoms}
  @struct_schema_key {__MODULE__, :struct_schema}
  @arg_modes_key {__MODULE__, :arg_modes}
  @min_scalar_integer -9_223_372_036_854_775_808
  @max_scalar_integer 9_223_372_036_854_775_807
  @min_term_integer -1_152_921_504_606_846_976
  @max_term_integer 1_152_921_504_606_846_975

  defmodule Error do
    @moduledoc "Raised when the frontend encounters an unsupported AST form."
    defexception [:message]
  end

  @doc """
  Builds a `builtin.module` of `ex.func` operations for the snapshot.

  Returns a `Beaver.Deferred`; materialize it with `Beaver.Deferred.resolve/2`
  against the MLIR context.
  """
  def module_to_ir(%Frontend.Module{} = mod, opts) do
    Beaver.Deferred.from_opts(opts, fn ctx ->
      unless ex_dialect_loaded?(ctx) do
        Beaver.Slang.load(ctx, Ex)
      end

      module = MLIR.Module.create!("module {}", ctx: ctx)
      body = MLIR.CAPI.mlirModuleGetBody(module)
      budget = Keyword.get(opts, :reduction_budget)
      batching = Keyword.get(opts, :reduction_batching) != false
      batch_size = reduction_batch_size(budget, batching)
      {workers, process_cap} = validate_runtime_options!(opts)
      known_atoms = opts |> Keyword.get(:atom_table, %{}) |> Enum.sort_by(&elem(&1, 0))
      {definitions, entry_name} = rename_entry(mod.definitions)

      definitions =
        definitions
        |> recognize_enum_calls()
        |> extract_all_fns()
        |> ensure_dynamic_apply_dispatch!()
        |> append_dispatch()

      schemas = Keyword.get(opts, :struct_schemas, Map.get(mod, :struct_schemas, %{}))

      schemas =
        if mod.struct_schema, do: Map.put(schemas, mod.name, mod.struct_schema), else: schemas

      module_env = %{
        @known_atoms_key => known_atoms,
        @struct_schema_key => schemas,
        @arg_modes_key => Batata.Signature.infer(definitions)
      }

      groups =
        definitions
        |> Enum.group_by(&{&1.name, &1.arity})
        |> Enum.sort_by(fn {{name, arity}, _definitions} -> {Atom.to_string(name), arity} end)

      enforce_resumable_plan(groups, budget)

      Enum.each(groups, fn {_key, definitions} ->
        lift_definitions(definitions, ctx, body, budget, batch_size, module_env)
      end)

      maybe_lift_driver(entry_name, definitions, ctx, body, budget, workers, process_cap)

      module
    end)
  end

  defp maybe_lift_driver(nil, _definitions, _ctx, _body, _budget, _workers, _process_cap),
    do: :ok

  defp maybe_lift_driver(entry_name, definitions, ctx, body, budget, workers, process_cap) do
    if driver_needed?(definitions, budget, workers) do
      lift_selected_driver(entry_name, definitions, ctx, body, budget, workers, process_cap)
    else
      lift_execution_driver(entry_name, ctx, body, process_cap)
    end

    lift_result_accessors(ctx, body)
  end

  defp lift_selected_driver(entry_name, definitions, ctx, body, budget, workers, process_cap) do
    has_dispatch = dispatch_exists?(definitions)

    if workers > 1 or definitions_may_raise?(definitions) do
      lift_actor_step(ctx, body, has_dispatch)
      lift_parallel_driver(entry_name, ctx, body, workers, process_cap)
    else
      lift_driver(entry_name, ctx, body, budget, has_dispatch, process_cap)
    end
  end

  defp reduction_batch_size(nil, _batching), do: nil
  defp reduction_batch_size(budget, true), do: budget
  defp reduction_batch_size(_budget, false), do: 1

  defp validate_runtime_options!(opts) do
    workers = Keyword.get(opts, :workers, 1)

    unless is_integer(workers) and workers >= 1 and workers <= 64 do
      raise Error, "workers must be an integer between 1 and 64"
    end

    process_cap = Keyword.get(opts, :process_cap) || 256

    unless is_integer(process_cap) and process_cap >= 1 and process_cap <= 4096 do
      raise Error, "process_cap must be an integer between 1 and 4096"
    end

    {workers, process_cap}
  end

  # The entry function (`main` for the JIT path, `batata_main` for the AOT
  # path) is renamed to `__batata_entry` so every host entry can establish an
  # isolated runtime session before executing user code. Scheduler drivers can
  # also re-invoke the renamed entry to resume a preempted process. Returns
  # {definitions, original_entry_name}.
  defp rename_entry(definitions) do
    case Enum.find(definitions, &entry_definition?/1) do
      nil ->
        {definitions, nil}

      %Frontend.Definition{name: entry_name} ->
        renamed =
          Enum.map(definitions, fn
            %Frontend.Definition{name: ^entry_name} = definition ->
              %{definition | name: :__batata_entry}

            definition ->
              definition
          end)

        {renamed, entry_name}
    end
  end

  defp entry_definition?(%Frontend.Definition{name: name, arity: 0}),
    do: name in [:main, :batata_main]

  defp entry_definition?(_), do: false

  # With a reduction budget every cursor loop becomes resumable; each process
  # owns a single (arg, acc, cursor) continuation slot, so a function may
  # contain at most one budgeted cursor loop in this slice.
  defp enforce_resumable_plan(_groups, nil), do: :ok

  defp enforce_resumable_plan(groups, _budget) do
    Enum.each(groups, &enforce_resumable_group!/1)
  end

  defp enforce_resumable_group!({_key, definitions}) do
    [%Frontend.Definition{name: name, arity: arity} | _] = definitions
    clauses = Enum.flat_map(definitions, & &1.clauses)
    scanner? = resumable_scanner?(definitions, name, arity, clauses)

    enum_loops =
      definitions
      |> Enum.map(&count_enum_cursor_loops/1)
      |> Enum.sum()

    total = if(scanner?, do: 1, else: 0) + enum_loops

    if total > 1 do
      raise Error,
            "preemptive multi-loop functions are unsupported in the scheduler slice: " <>
              "#{name} has #{total} budgeted cursor loops (one continuation slot per process)"
    end
  end

  defp resumable_scanner?([_definition], _name, _arity, _clauses), do: false

  defp resumable_scanner?(_definitions, name, 1, clauses),
    do: match?({:ok, _}, detect_scanner(name, clauses))

  defp resumable_scanner?(_definitions, name, arity, clauses) when arity >= 2,
    do: match?({:ok, _}, detect_accumulator_scanner(name, clauses))

  defp resumable_scanner?(_definitions, _name, _arity, _clauses), do: false

  defp count_enum_cursor_loops(%Frontend.Definition{clauses: clauses}) do
    clauses
    |> Enum.map(fn %Frontend.Clause{body_ast: body_ast} ->
      count_enum_cursor_loops_ast(body_ast)
    end)
    |> Enum.sum()
  end

  defp count_enum_cursor_loops_ast(ast) do
    ast
    |> Macro.prewalk(0, fn
      {:__enum_call__, _, [:reduce, pattern, enumerable_ast, _acc]} = node, acc ->
        {node, acc + if(cursor_loop_reduce?(pattern, enumerable_ast), do: 1, else: 0)}

      {:__enum_call__, _, [:map, pattern, _enumerable]} = node, acc ->
        {node, acc + if(cursor_loop_map?(pattern), do: 1, else: 0)}

      {{:., _, [:lists, function]}, _, args} = node, acc
      when function in [:keyfind, :reverse] and is_list(args) ->
        {node, acc + 1}

      {{:., _, [module_ast, :get]}, _, args} = node, acc when length(args) in [2, 3] ->
        {node, acc + if(module_ref(module_ast) == {:ok, Keyword}, do: 1, else: 0)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp cursor_loop_reduce?(pattern, enumerable_ast) do
    is_list(enumerable_ast) and
      pattern in [:sum, :product, :subtract_acc_first, :subtract_item_first]
  end

  defp cursor_loop_map?(pattern) do
    match?({:const, _}, pattern) or match?({:add_capture, _}, pattern)
  end

  # The scheduler variant of the execution driver is generated when a
  # reduction budget is set (the entry may be preempted and must be resumed)
  # or when the source spawns processes (they must be executed to completion).
  defp driver_needed?(definitions, budget, workers) do
    workers > 1 or budget != nil or definitions_may_raise?(definitions) or
      Enum.any?(definitions, &definition_spawns?/1)
  end

  defp definitions_may_raise?(definitions) do
    definitions
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.any?(fn {_key, group} ->
      clauses = Enum.flat_map(group, & &1.clauses)

      (length(clauses) > 1 and not function_clause_catch_all?(List.last(clauses))) or
        (length(clauses) == 1 and Enum.any?(clauses, &function_clause_requires_dispatch?/1))
    end) or Enum.any?(definitions, &definition_has_non_exhaustive_case?/1) or
      Enum.any?(definitions, &definition_uses_native_raise?/1)
  end

  defp definition_uses_native_raise?(%Frontend.Definition{clauses: clauses}) do
    Enum.any?(clauses, fn %Frontend.Clause{body_ast: body} -> ast_uses_native_raise?(body) end)
  end

  defp ast_uses_native_raise?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {:<>, _, [_, _]} = node, false ->
          {node, true}

        {:%{}, _, [{:|, _, [_base, _updates]}]} = node, false ->
          {node, true}

        {name, _, args} = node, false when is_atom(name) and is_list(args) ->
          {node, Batata.Stdlib.may_raise?({Kernel, name, length(args)})}

        {{:., _, [module_ast, name]}, _, args} = node, false
        when is_atom(name) and is_list(args) ->
          raises? =
            case module_ref(module_ast) do
              {:ok, module} -> Batata.Stdlib.may_raise?({module, name, length(args)})
              :error -> false
            end

          {node, raises?}

        node, false ->
          {node, false}
      end)

    found?
  end

  defp function_clause_catch_all?(%Frontend.Clause{patterns: patterns, guard_ast: nil}) do
    Enum.all?(patterns, &match?({name, _, nil} when is_atom(name), &1))
  end

  defp function_clause_catch_all?(_clause), do: false

  defp function_clause_has_pattern?(%Frontend.Clause{patterns: patterns}) do
    Enum.any?(patterns, fn
      {name, _, nil} when is_atom(name) -> false
      _pattern -> true
    end)
  end

  defp function_clause_requires_dispatch?(%Frontend.Clause{guard_ast: guard_ast} = clause) do
    guard_ast != nil or function_clause_has_pattern?(clause)
  end

  defp definition_has_non_exhaustive_case?(%Frontend.Definition{clauses: clauses}) do
    Enum.any?(clauses, fn %Frontend.Clause{body_ast: body} ->
      ast_has_non_exhaustive_case?(body)
    end)
  end

  defp ast_has_non_exhaustive_case?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:case, _, [_value, [do: clauses]]} = node, found? ->
          {node, found? or not Enum.any?(clauses, &clause_catch_all?/1)}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp definition_spawns?(%Frontend.Definition{clauses: clauses}) do
    Enum.any?(clauses, fn %Frontend.Clause{body_ast: body_ast} -> ast_spawns?(body_ast) end)
  end

  defp dispatch_exists?(definitions) do
    Enum.any?(definitions, &fn_definition?/1)
  end

  defp ast_spawns?(ast) do
    ast
    |> Macro.prewalk(false, fn
      node, true ->
        {node, true}

      {:spawn, _, [_fun]}, _ ->
        {nil, true}

      {{:., _, [{:__aliases__, _, [:Kernel]}, :spawn]}, _, [_fun]}, _ ->
        {nil, true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # `Beaver.Slang.load/2` registers the IRDL ops in the context and is not
  # idempotent: loading the same dialect twice crashes MLIR with an operation
  # registration assertion. Skip it when the ex dialect is already present.
  defp ex_dialect_loaded?(ctx) do
    ctx
    |> MLIR.CAPI.mlirContextIsRegisteredOperation(MLIR.StringRef.create("ex.box"))
    |> Beaver.Native.to_term()
  end

  # Extracts anonymous-function literals from every definition body into
  # synthetic `defp` definitions, replacing the literal with a
  # `{:__fn_ref__, _, [fn_idx, name, arity, captured]}` marker. The synthetic
  # definition uses the fixed closure ABI: four captured-value slots followed
  # by four argument slots. The application site threads the captured values
  # from the outer env.
  defp extract_all_fns(definitions) do
    {defs, {synthetic, _counter}} =
      definitions
      |> Enum.map_reduce({[], 0}, fn defn, {synthetic, counter} ->
        {clauses, {synthetic, counter}} =
          defn.clauses
          |> Enum.map_reduce({synthetic, counter}, fn clause, {synthetic, counter} ->
            {body_ast, {synthetic, counter}} =
              extract_fns(clause.body_ast, defn.name, {synthetic, counter})

            {%{clause | body_ast: body_ast}, {synthetic, counter}}
          end)

        {%{defn | clauses: clauses}, {synthetic, counter}}
      end)

    defs ++ synthetic
  end

  defp ensure_dynamic_apply_dispatch!(definitions) do
    if Enum.any?(definitions, &definition_has_dynamic_apply?/1) and
         not Enum.any?(definitions, &fn_definition?/1) do
      raise Error,
            "dynamic_apply_without_local_dispatch: dynamic function application requires " <>
              "at least one module-local anonymous function"
    end

    definitions
  end

  defp definition_has_dynamic_apply?(%Frontend.Definition{clauses: clauses}) do
    Enum.any?(clauses, fn %Frontend.Clause{body_ast: body_ast} -> dynamic_apply?(body_ast) end)
  end

  defp dynamic_apply?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__fn_ref__, _, _}]}, _, args} = node, found? when is_list(args) ->
          {node, found?}

        {{:., _, [_fun_ast]}, _, args} = node, _found? when is_list(args) ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  # Recognizes `Enum.map/2` and `Enum.reduce/3` calls whose mapper/reducer
  # matches a supported pattern (identity map, const map, sum/return-acc
  # reduce) and replaces the call with an internal `__enum_call__` marker, so
  # the fn literal is not extracted into a closure. Unsupported shapes are
  # left untouched and raise later through the stdlib registry.
  defp recognize_enum_calls(definitions) do
    {defs, {synthetic, _counter}} =
      definitions
      |> Enum.map_reduce({[], 0}, fn definition, state ->
        {clauses, state} =
          definition.clauses
          |> Enum.map_reduce(state, fn clause, state ->
            {body_ast, state} = recognize_enum_calls_ast(clause.body_ast, state)
            {%{clause | body_ast: body_ast}, state}
          end)

        {%{definition | clauses: clauses}, state}
      end)

    defs ++ synthetic
  end

  defp recognize_enum_calls_ast(ast, state) do
    Macro.prewalk(ast, state, fn
      node, acc ->
        recognize_enum_node(node, acc)
    end)
  end

  defp recognize_enum_node(
         {{:., _, [{:__aliases__, _, alias_parts}, :map]}, _, [enumerable, fn_ast]} = node,
         state
       ) do
    if enum_alias?(alias_parts) or stream_alias?(alias_parts) do
      recognize_map_node(fn_ast, enumerable, node, state)
    else
      {node, state}
    end
  end

  defp recognize_enum_node(
         {{:., _, [{:__aliases__, _, alias_parts}, :filter]}, _, [enumerable, fn_ast]} = node,
         state
       ) do
    if stream_alias?(alias_parts) do
      recognize_filter_node(fn_ast, enumerable, node, state)
    else
      {node, state}
    end
  end

  defp recognize_enum_node(
         {{:., _, [{:__aliases__, _, alias_parts}, :reduce]}, _, [enumerable, acc, fn_ast]} =
           node,
         state
       ) do
    if enum_alias?(alias_parts) do
      recognize_reduce_node(fn_ast, enumerable, acc, node, state)
    else
      {node, state}
    end
  end

  defp recognize_enum_node(node, state), do: {node, state}

  defp recognize_map_node(fn_ast, enumerable, node, state) do
    case map_pattern(fn_ast) do
      {:ok, {:mapper, body_ast, item_name}} ->
        extract_mapper(body_ast, item_name, enumerable, state)

      {:ok, pattern} ->
        {{:__enum_call__, [], [:map, pattern, enumerable]}, state}

      :error ->
        {node, state}
    end
  end

  defp recognize_filter_node(fn_ast, enumerable, node, state) do
    case predicate_pattern(fn_ast) do
      {:ok, body_ast, item_name} -> extract_predicate(body_ast, item_name, enumerable, state)
      :error -> {node, state}
    end
  end

  defp recognize_reduce_node(fn_ast, enumerable, acc, node, state) do
    case reduce_pattern(fn_ast) do
      {:ok, {:combination, body_ast, item_name, acc_name}} ->
        extract_combination_reducer(body_ast, item_name, acc_name, enumerable, acc, state)

      {:ok, pattern} ->
        {{:__enum_call__, [], [:reduce, pattern, enumerable, acc]}, state}

      :error ->
        {node, state}
    end
  end

  # Combination reducers become synthetic `__enum_reducer_N` definitions so
  # any enumerable can call them through the runtime's arbitrary-closure
  # reduce.
  defp extract_combination_reducer(body_ast, item_name, acc_name, enumerable, acc, state) do
    {synthetic, counter} = state
    reducer_name = :"__enum_reducer_#{counter}"

    reducer_def = %Frontend.Definition{
      kind: :defp,
      name: reducer_name,
      arity: 2,
      clauses: [
        %Frontend.Clause{
          patterns: [{item_name, [], nil}, {acc_name, [], nil}],
          body_ast: body_ast
        }
      ]
    }

    marker = {:__enum_call__, [], [:reduce, {:combination, reducer_name}, enumerable, acc]}
    {marker, {[reducer_def | synthetic], counter + 1}}
  end

  # Arbitrary arithmetic mappers become synthetic `__enum_mapper_N`
  # definitions called through the runtime's compiled-mapper map.
  defp extract_mapper(body_ast, item_name, enumerable, state) do
    {synthetic, counter} = state
    mapper_name = :"__enum_mapper_#{counter}"

    mapper_def = %Frontend.Definition{
      kind: :defp,
      name: mapper_name,
      arity: 1,
      clauses: [
        %Frontend.Clause{
          patterns: [{item_name, [], nil}],
          body_ast: body_ast
        }
      ]
    }

    marker = {:__enum_call__, [], [:map, {:mapper, mapper_name}, enumerable]}
    {marker, {[mapper_def | synthetic], counter + 1}}
  end

  # Stream.filter predicates become synthetic `__stream_pred_N` definitions
  # called through the runtime's compiled-predicate filter.
  defp extract_predicate(body_ast, item_name, enumerable, state) do
    {synthetic, counter} = state
    predicate_name = :"__stream_pred_#{counter}"

    predicate_def = %Frontend.Definition{
      kind: :defp,
      name: predicate_name,
      arity: 1,
      clauses: [
        %Frontend.Clause{
          patterns: [{item_name, [], nil}],
          body_ast: body_ast
        }
      ]
    }

    marker = {:__enum_call__, [], [:stream_filter, predicate_name, enumerable]}
    {marker, {[predicate_def | synthetic], counter + 1}}
  end

  # `fn item -> cond end`: predicate body must be a slice-compilable
  # expression over the item (comparisons, arithmetic, is_*).
  defp predicate_pattern({:fn, _, [{:->, _, [[item], body]}]}) do
    vars =
      body
      |> collect_all_vars()
      |> MapSet.new()

    if MapSet.subset?(vars, MapSet.new([tree_var_name(item)])) do
      {:ok, body, tree_var_name(item)}
    else
      :error
    end
  end

  defp predicate_pattern(_), do: :error

  defp enum_alias?([:Enum]), do: true
  defp enum_alias?([:"Elixir", :Enum]), do: true
  defp enum_alias?(_), do: false
  defp stream_alias?([:Stream]), do: true
  defp stream_alias?([:"Elixir", :Stream]), do: true
  defp stream_alias?(_), do: false

  defp map_pattern({:fn, _, [{:->, _, [[item], body]}]}) do
    cond do
      same_var?(body, item) ->
        {:ok, :identity}

      is_integer(body) ->
        {:ok, {:const, body}}

      true ->
        case capture_add(body, item) do
          {:ok, capture_ast} ->
            {:ok, {:add_capture, capture_ast}}

          :error ->
            arithmetic_mapper_pattern(body, item)
        end
    end
  end

  defp map_pattern(_), do: :error

  defp arithmetic_mapper_pattern(body, item) do
    if arithmetic_tree?(body) and
         body
         |> collect_tree_vars()
         |> MapSet.new()
         |> MapSet.subset?(MapSet.new([tree_var_name(item)])) do
      {:ok, {:mapper, body, tree_var_name(item)}}
    else
      :error
    end
  end

  defp reduce_pattern({:fn, _, [{:->, _, [[item, acc_var], body]}]}) do
    with :error <- basic_reduce_pattern(body, item, acc_var),
         :error <- captured_reduce_pattern(body, item, acc_var),
         :error <- map_reduce_pattern(body, item, acc_var) do
      terminal_reduce_pattern(body, item, acc_var)
    end
  end

  defp reduce_pattern(_), do: :error

  defp basic_reduce_pattern(body, item, acc_var) do
    cond do
      sum_pattern?(body, item, acc_var) ->
        {:ok, :sum}

      product_pattern?(body, item, acc_var) ->
        {:ok, :product}

      subtract_pattern?(body, item, acc_var) ->
        {:ok, subtract_direction(body, item, acc_var)}

      div_rem_pattern?(body, item, acc_var) ->
        {:ok, div_rem_direction(body, item, acc_var)}

      true ->
        :error
    end
  end

  defp captured_reduce_pattern(body, item, acc_var) do
    cond do
      capture_sum_pattern?(body, item, acc_var) ->
        {:ok, capture} = capture_addend(body, item, acc_var)
        {:ok, {:capture_sum, capture}}

      capture_product_pattern?(body, item, acc_var) ->
        capture = capture_product_addend(body, item)
        {:ok, {:capture_product, capture}}

      true ->
        :error
    end
  end

  defp map_reduce_pattern(body, item, acc_var) do
    cond do
      map_values_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_values_sum}

      map_keys_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_keys_sum}

      map_entries_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_entries_sum}

      true ->
        :error
    end
  end

  defp terminal_reduce_pattern(body, item, acc_var) do
    cond do
      same_var?(body, acc_var) ->
        {:ok, :return_acc}

      combination_pattern?(body, item, acc_var) ->
        {:ok, {:combination, body, tree_var_name(item), tree_var_name(acc_var)}}

      true ->
        :error
    end
  end

  defp sum_pattern?({:+, _, [left, right]}, item, acc_var) do
    (same_var?(left, item) and same_var?(right, acc_var)) or
      (same_var?(left, acc_var) and same_var?(right, item))
  end

  defp sum_pattern?(_body, _item, _acc_var), do: false

  # `fn item, acc -> item * acc end` / `acc * item`: product accumulation.
  defp product_pattern?({:*, _, [left, right]}, item, acc_var) do
    (same_var?(left, item) and same_var?(right, acc_var)) or
      (same_var?(left, acc_var) and same_var?(right, item))
  end

  defp product_pattern?(_body, _item, _acc_var), do: false

  # `fn item, acc -> acc - item end` (acc first) and `item - acc` (item
  # first): subtraction is order-sensitive.
  defp subtract_pattern?({:-, _, [left, right]}, item, acc_var) do
    (same_var?(left, acc_var) and same_var?(right, item)) or
      (same_var?(left, item) and same_var?(right, acc_var))
  end

  defp subtract_pattern?(_body, _item, _acc_var), do: false

  defp subtract_direction({:-, _, [left, _right]}, _item, acc_var) do
    if same_var?(left, acc_var), do: :subtract_acc_first, else: :subtract_item_first
  end

  # `fn item, acc -> div(item, acc) end` / `rem(item, acc)` and the
  # accumulator-first variants. Both are order-sensitive.
  defp div_rem_pattern?({op, _, [left, right]}, item, acc_var) when op in [:div, :rem] do
    (same_var?(left, acc_var) and same_var?(right, item)) or
      (same_var?(left, item) and same_var?(right, acc_var))
  end

  defp div_rem_pattern?(_body, _item, _acc_var), do: false

  defp div_rem_direction({op, _, [left, _right]}, _item, acc_var) do
    prefix = if op == :div, do: :div, else: :rem
    if same_var?(left, acc_var), do: :"#{prefix}_acc_first", else: :"#{prefix}_item_first"
  end

  # `fn item, acc -> acc + item + capture end` / `capture + item + acc`:
  # sum with a captured scalar (variable or integer literal).
  defp capture_sum_pattern?(body, item, acc_var) do
    match?({:ok, _capture}, capture_addend(body, item, acc_var))
  end

  defp capture_addend({:+, _, [left, right]}, item, acc_var) do
    cond do
      sum_pattern?(left, item, acc_var) and addend?(right) -> {:ok, right}
      sum_pattern?(right, item, acc_var) and addend?(left) -> {:ok, left}
      true -> :error
    end
  end

  defp capture_addend(_body, _item, _acc_var), do: :error

  # `fn item, acc -> acc + item * capture end` / `item * capture + acc`:
  # product with a captured scalar.
  defp capture_product_pattern?({:+, _, [left, right]}, item, acc_var) do
    (capture_product_addend(left, item) != nil and same_var?(right, acc_var)) or
      (capture_product_addend(right, item) != nil and same_var?(left, acc_var))
  end

  defp capture_product_pattern?(_body, _item, _acc_var), do: false

  defp capture_product_addend({:+, _, [left, right]}, item) do
    capture_product_addend(left, item) || capture_product_addend(right, item)
  end

  defp capture_product_addend({:*, _, [left, right]}, item) do
    cond do
      same_var?(left, item) and addend?(right) -> right
      same_var?(right, item) and addend?(left) -> left
      true -> nil
    end
  end

  defp capture_product_addend(_body, _item), do: nil

  # `fn {_k, v}, acc -> acc + v end` / `v + acc`: map value accumulation.
  defp map_values_sum_pattern?(body, item, acc_var),
    do: map_entry_add_pattern?(body, item, acc_var, :value)

  # `fn {k, _v}, acc -> acc + k end` / `k + acc`: map key accumulation.
  defp map_keys_sum_pattern?(body, item, acc_var),
    do: map_entry_add_pattern?(body, item, acc_var, :key)

  # `fn {k, v}, acc -> acc + k + v end` (any addition order): the body must be
  # a pure addition tree over exactly the key, value, and accumulator
  # variables, each once.
  defp map_entries_sum_pattern?(body, item, acc_var) do
    case map_entry_vars(item) do
      {:ok, key_var, value_var} ->
        body
        |> collect_add_vars()
        |> MapSet.new()
        |> MapSet.equal?(
          MapSet.new([tree_var_name(key_var), tree_var_name(value_var), tree_var_name(acc_var)])
        )

      :error ->
        false
    end
  end

  defp map_entry_add_pattern?({:+, _, [left, right]}, item, acc_var, selector) do
    case map_entry_var(item, selector) do
      {:ok, entry_var} ->
        (same_var?(left, entry_var) and same_var?(right, acc_var)) or
          (same_var?(left, acc_var) and same_var?(right, entry_var))

      :error ->
        false
    end
  end

  defp map_entry_add_pattern?(_body, _item, _acc_var, _selector), do: false

  # Two-element tuple patterns parse as 2-tuples in quoted form (`{_k, v}`),
  # unlike arity >= 3 tuple literals which are `{:{}, meta, elems}`.
  defp map_entry_var({{key, _, _}, {_value, _, _}}, :key) when is_atom(key),
    do: {:ok, {key, [], nil}}

  defp map_entry_var({{_key, _, _}, {value, _, _}}, :value) when is_atom(value),
    do: {:ok, {value, [], nil}}

  defp map_entry_var(_item, _selector), do: :error

  defp map_entry_vars({{key, _, _}, {value, _, _}})
       when is_atom(key) and is_atom(value) and key != value,
       do: {:ok, {key, [], nil}, {value, [], nil}}

  defp map_entry_vars(_item), do: :error

  defp collect_add_vars({:+, _, [left, right]}),
    do: collect_add_vars(left) ++ collect_add_vars(right)

  defp collect_add_vars({name, _, _}) when is_atom(name), do: [name]
  defp collect_add_vars(_), do: []

  defp tree_var_name({name, _, _}), do: name

  # Combination reducer: the body is a pure arithmetic tree (+/-/*) over the
  # item, the accumulator, and integer literals — now generalized to any
  # slice-compilable body whose variables come only from item/acc (the body
  # is compiled into the extracted reducer function; unsupported forms
  # surface as explicit lift errors).
  defp combination_pattern?(body, item, acc_var) do
    body
    |> collect_all_vars()
    |> MapSet.new()
    |> MapSet.subset?(MapSet.new([tree_var_name(item), tree_var_name(acc_var)]))
  end

  defp arithmetic_tree?({op, _, [left, right]}) when op in [:+, :-, :*],
    do: arithmetic_tree?(left) and arithmetic_tree?(right)

  defp arithmetic_tree?(integer) when is_integer(integer), do: true
  defp arithmetic_tree?({name, _, _}) when is_atom(name), do: true
  defp arithmetic_tree?(_), do: false

  defp collect_tree_vars({op, _, [left, right]}) when op in [:+, :-, :*],
    do: collect_tree_vars(left) ++ collect_tree_vars(right)

  defp collect_tree_vars({name, _, _}) when is_atom(name), do: [name]
  defp collect_tree_vars(_), do: []

  # Variables in arbitrary AST: `{name, meta, ctx}` where ctx is an atom or
  # nil is a variable; a list ctx means a call (or a non-variable node).
  defp collect_all_vars({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: [name]

  defp collect_all_vars({_name, _, args}) when is_list(args),
    do: Enum.flat_map(args, &collect_all_vars/1)

  defp collect_all_vars(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&collect_all_vars/1)

  defp collect_all_vars(list) when is_list(list),
    do: Enum.flat_map(list, &collect_all_vars/1)

  defp collect_all_vars(_), do: []

  # `fn item -> item + capture end` / `capture + item` where capture is a free
  # variable of the fn (resolved from the enclosing env) or an integer
  # literal.
  defp capture_add({:+, _, [left, right]}, item) do
    cond do
      same_var?(left, item) and addend?(right) -> {:ok, right}
      same_var?(right, item) and addend?(left) -> {:ok, left}
      true -> :error
    end
  end

  defp capture_add(_body, _item), do: :error

  defp addend?({name, _, _}) when is_atom(name), do: true
  defp addend?(value) when is_integer(value), do: true
  defp addend?(_), do: false

  defp same_var?({name, _, _}, {name, _, _}) when is_atom(name), do: true
  defp same_var?(_left, _right), do: false

  defp extract_fns({:fn, _, [{:->, _, [args, body]}]}, parent, {synthetic, counter}) do
    name = :"__fn_#{parent}_#{counter}"
    arity = length(args)
    bound = Enum.map(args, &param_name/1)
    captured = body |> free_vars(bound) |> Enum.uniq() |> Enum.sort()

    unless arity <= 4 and length(captured) <= 4 do
      raise Error,
            "anonymous functions are limited to 4 arguments and 4 captured variables: " <>
              "#{arity} arguments, #{length(captured)} captured"
    end

    patterns =
      ((captured ++ List.duplicate(nil, 4 - length(captured))) ++
         bound ++ List.duplicate(nil, 4 - arity))
      |> Enum.map(fn
        nil -> {:_, [], nil}
        name -> {name, [], nil}
      end)

    fn_def = %Frontend.Definition{
      kind: :defp,
      name: name,
      arity: 8,
      clauses: [%Frontend.Clause{patterns: patterns, body_ast: body}]
    }

    marker = {:__fn_ref__, [], [counter, name, arity, captured]}
    {marker, {synthetic ++ [fn_def], counter + 1}}
  end

  defp extract_fns(tuple, parent, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map_reduce(acc, &extract_fns(&1, parent, &2))
    |> then(fn {elements, acc} -> {List.to_tuple(elements), acc} end)
  end

  defp extract_fns([head | tail], parent, acc) do
    {head, acc} = extract_fns(head, parent, acc)
    {tail, acc} = extract_fns(tail, parent, acc)
    {[head | tail], acc}
  end

  defp extract_fns(other, _parent, acc), do: {other, acc}

  # Collects variable references in an AST that are not bound by `bound`.
  # Nested fn literals are skipped: their bodies bind and reference variables
  # in their own scope, and each literal is extracted independently.
  defp free_vars({:fn, _, _}, _bound), do: []

  defp free_vars({var, _, nil}, bound) when is_atom(var) do
    if var == :_ or var in bound, do: [], else: [var]
  end

  defp free_vars({{:., _, [fun]}, _, args}, bound) when is_list(args) do
    free_vars(fun, bound) ++ Enum.flat_map(args, &free_vars(&1, bound))
  end

  defp free_vars({_name, _, args}, bound) when is_list(args) do
    Enum.flat_map(args, &free_vars(&1, bound))
  end

  defp free_vars(tuple, bound) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&free_vars(&1, bound))
  end

  defp free_vars(list, bound) when is_list(list) do
    Enum.flat_map(list, &free_vars(&1, bound))
  end

  defp free_vars(_other, _bound), do: []

  # Appends the closure dispatch function: it reads the function index and
  # env words from a closure (via the Zig runtime) and jumps to the matching
  # `__fn_*` with the fixed 8-slot ABI. Built only when at least one
  # anonymous function exists.
  defp append_dispatch(definitions) do
    fns =
      definitions
      |> Enum.filter(&fn_definition?(&1))
      |> Enum.map(fn defn ->
        idx =
          defn.name
          |> Atom.to_string()
          |> String.split("_")
          |> List.last()
          |> String.to_integer()

        {idx, defn.name}
      end)
      |> Enum.sort()

    case fns do
      [] -> definitions
      _ -> definitions ++ [dispatch_definition(fns)]
    end
  end

  defp fn_definition?(%Frontend.Definition{name: name}) do
    name |> Atom.to_string() |> String.starts_with?("__fn_")
  end

  defp dispatch_definition([{_, first_name} | _] = fns) do
    vars = [:idx, :e0, :e1, :e2, :e3, :a0, :a1, :a2, :a3]
    call_args = Enum.map(tl(vars), &{&1, [], nil})
    zero_args = List.duplicate(0, 8)

    clauses =
      Enum.map(fns, fn {idx, name} ->
        {:->, [], [[idx], {name, [], call_args}]}
      end) ++ [{:->, [], [[{:_, [], nil}], {first_name, [], zero_args}]}]

    %Frontend.Definition{
      kind: :defp,
      name: :__fn_dispatch,
      arity: length(vars),
      clauses: [
        %Frontend.Clause{
          patterns: Enum.map(vars, &{&1, [], nil}),
          body_ast: {:case, [], [{:idx, [], nil}, [do: clauses]]}
        }
      ]
    }
  end

  defp lift_definition(
         %Frontend.Definition{kind: kind, name: name, arity: arity, clauses: clauses},
         ctx,
         ip,
         budget,
         batch_size,
         module_env
       ) do
    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    unless length(clauses) == 1 do
      raise Error, "multiple clauses are unsupported in the scalar slice: #{name}/#{arity}"
    end

    [%Frontend.Clause{patterns: patterns, guard_ast: guard_ast, body_ast: body_ast}] = clauses

    if guard_ast do
      raise Error,
            "a guarded function requires a following fallback clause: #{name}/#{arity}"
    end

    region = MLIR.CAPI.mlirRegionCreate()
    arg_types = List.duplicate(integer_type(ctx), length(patterns))
    arg_locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), length(patterns))
    block = MLIR.Block.create(arg_types, arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    env =
      block
      |> Walker.arguments()
      |> Enum.to_list()
      |> Enum.zip(Enum.zip(patterns, function_arg_modes(name, arity, module_env)))
      |> Enum.reduce(module_env, fn {value, {pattern, mode}}, env ->
        Map.put(env, param_name(pattern), inbound_argument(value, mode, ctx, block))
      end)
      |> Map.put(:__budget__, budget)
      |> Map.put(:__batch_size__, batch_size)

    # The entry function starts a fresh actor: reset the mailbox and the
    # reduction clock so each program run observes a clean process (#35).
    # Without a reduction budget no clock op is emitted at all (#41 fast
    # path); with a budget the mailbox is cleared only on the first slice so
    # a resumed slice keeps messages that arrived while it was suspended.
    if name in [:__batata_entry, :main] and uses_mailbox?(body_ast) do
      if budget == nil do
        create_op("ex.mailbox_clear", [], [ex_type("term", ctx)], ctx, block)
      else
        active = create_op("ex.cont_active", [], [integer_type(ctx)], ctx, block)

        active_i1 =
          create_op("arith.trunci", [active], [MLIR.Type.i1()], ctx, block)

        resume_region = MLIR.CAPI.mlirRegionCreate()
        resume_block = MLIR.Block.create([], [])
        MLIR.CAPI.mlirRegionAppendOwnedBlock(resume_region, resume_block)
        create_op("scf.yield", [], [], ctx, resume_block)

        fresh_region = MLIR.CAPI.mlirRegionCreate()
        fresh_block = MLIR.Block.create([], [])
        MLIR.CAPI.mlirRegionAppendOwnedBlock(fresh_region, fresh_block)
        create_op("ex.mailbox_clear", [], [ex_type("term", ctx)], ctx, fresh_block)
        create_op("scf.yield", [], [], ctx, fresh_block)

        %Beaver.SSA{
          op: "scf.if",
          ip: block,
          ctx: ctx,
          arguments: [active_i1],
          results: [],
          loc: MLIR.Location.unknown(),
          filler: fn -> [resume_region, fresh_region] end
        }
        |> MLIR.Operation.create()
      end
    end

    if name in [:__batata_entry, :main] and budget != nil do
      create_op("ex.clock_init", [lit(budget, ctx, block)], [integer_type(ctx)], ctx, block)
    end

    {return_value, env} = lift_block(block_ast(body_ast), ctx, block, env)
    insert_return(return_value, ctx, block, env)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(Symbol.function(name, arity))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp block_ast(nil), do: [nil]
  defp block_ast({:__block__, _, expressions}), do: expressions
  defp block_ast(ast), do: [ast]

  defp uses_mailbox?(ast) do
    ast
    |> Macro.prewalk(false, fn
      node, true ->
        {node, true}

      {:receive, _, _}, _ ->
        {nil, true}

      {:send, _, _}, _ ->
        {nil, true}

      {:self, _, []}, _ ->
        {nil, true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp validate_single_definition_guards!(clauses) do
    Enum.each(clauses, fn
      %Frontend.Clause{guard_ast: nil} ->
        :ok

      %Frontend.Clause{guard_ast: guard_ast} ->
        unless GuardSupport.compiler_supported?(guard_ast) do
          raise Error, "unsupported guard on term pattern: #{inspect(guard_ast)}"
        end
    end)
  end

  defp lift_definitions(
         [%Frontend.Definition{name: name, arity: arity, clauses: clauses}] = definitions,
         ctx,
         ip,
         budget,
         batch_size,
         module_env
       ) do
    if Enum.any?(clauses, &function_clause_requires_dispatch?/1) do
      validate_single_definition_guards!(clauses)
      opts = term_case_opts(name, arity, module_env)

      case arity do
        0 -> raise Error, "guarded zero-arity definitions are unsupported: #{name}/0"
        1 -> lift_multi_clause_dispatch(name, clauses, ctx, ip, module_env, opts)
        n when n >= 2 -> lift_multi_arg_dispatch(name, arity, clauses, ctx, ip, module_env, opts)
      end
    else
      lift_definition(hd(definitions), ctx, ip, budget, batch_size, module_env)
    end
  end

  # Multiple `def` forms with the same name/arity become one ex.func whose
  # body dispatches on the argument with ex.case, matching each clause's
  # pattern (the cursor-loop foundation for recursive scanners). M2 requires
  # a single argument and a final catch-all clause.
  defp lift_definitions(definitions, ctx, ip, budget, batch_size, module_env) do
    %Frontend.Definition{kind: kind, name: name, arity: arity} = hd(definitions)

    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    clauses = Enum.flat_map(definitions, & &1.clauses)
    opts = term_case_opts(name, arity, module_env)

    cond do
      arity == 1 ->
        case detect_scanner(name, clauses) do
          {:ok, scanner} -> lift_scanner_loop(name, scanner, ctx, ip, budget, batch_size)
          :skip -> lift_multi_clause_dispatch(name, clauses, ctx, ip, module_env, opts)
        end

      arity >= 2 ->
        case detect_accumulator_scanner(name, clauses) do
          {:ok, scanner} -> lift_reduce_loop(name, scanner, ctx, ip, budget, batch_size)
          :skip -> lift_multi_arg_dispatch(name, arity, clauses, ctx, ip, module_env, opts)
        end

      true ->
        raise Error, "unsupported function arity: #{name}/#{arity}"
    end
  end

  defp lift_multi_clause_dispatch(name, clauses, ctx, ip, module_env, opts) do
    region = MLIR.CAPI.mlirRegionCreate()

    # The argument is a scalar word (like single-clause functions); the term
    # path re-types it with ex.to_word when term reads are involved.
    arg_locs = [MLIR.Location.unknown(ctx: ctx)]
    block = MLIR.Block.create([integer_type(ctx)], arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg] = block |> Walker.arguments() |> Enum.to_list()

    clause_asts =
      Enum.map(clauses, fn %Frontend.Clause{
                             patterns: [pattern],
                             guard_ast: guard_ast,
                             body_ast: body_ast
                           } ->
        args = if guard_ast, do: [{:when, [], [pattern, guard_ast]}], else: [pattern]
        {:->, [], [args, body_ast]}
      end)

    return_value =
      lift_case(
        clause_asts,
        arg,
        module_env,
        ctx,
        block,
        Keyword.merge(
          [
            relax_types: true,
            box_scrutinee: false,
            untag_int_binds: true,
            failure_kind: 2,
            failure_reason: {:{}, [], [name, 1, [{:__batata_unmatched__, [], nil}]]}
          ],
          opts
        )
      )

    insert_return(return_value, ctx, block, %{})

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(Symbol.function(name, 1))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  # Multi-argument multi-clause functions (e.g. `reduce(binary, acc)`): the
  # first argument dispatches with `ex.case`; trailing variable names are
  # clause-local aliases for the same positional function arguments. A
  # compile-known atom literal in a trailing position contributes an extra
  # clause condition over that argument.
  defp lift_multi_arg_dispatch(name, arity, clauses, ctx, ip, module_env, opts) do
    clause_tail_patterns = validate_multi_arg_clauses!(arity, clauses)

    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)
    i64 = integer_type(ctx)
    locs = List.duplicate(loc, arity)

    block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg1 | tail_args] = block |> Walker.arguments() |> Enum.to_list()

    [_first_mode | tail_modes] = function_arg_modes(name, arity, module_env)

    tail_modes =
      tail_modes
      |> Enum.with_index()
      |> Enum.map(fn {mode, index} ->
        if Enum.any?(clause_tail_patterns, &tail_term_pattern?(Enum.at(&1, index))),
          do: :term,
          else: mode
      end)

    tail_args =
      Enum.zip_with(tail_args, tail_modes, &inbound_argument(&1, &2, ctx, block))

    {extra_clause_conds, clause_bindss} =
      clause_tail_patterns
      |> Enum.map(&tail_match(&1, tail_args, ctx, block, module_env))
      |> Enum.unzip()

    failure_tail_names =
      Enum.map(1..(arity - 1), &String.to_atom("__batata_tail_arg_#{&1}"))

    fallback_binds = tail_bindings(failure_tail_names, tail_args)

    clause_asts =
      Enum.map(clauses, fn %Frontend.Clause{
                             patterns: [first | _],
                             guard_ast: guard_ast,
                             body_ast: body_ast
                           } ->
        args = if guard_ast, do: [{:when, [], [first, guard_ast]}], else: [first]
        {:->, [], [args, body_ast]}
      end)

    return_value =
      lift_case(
        clause_asts,
        arg1,
        module_env,
        ctx,
        block,
        Keyword.merge(
          [
            relax_types: true,
            box_scrutinee: false,
            untag_int_binds: true,
            clause_bindss: clause_bindss,
            extra_clause_conds: extra_clause_conds,
            force_fallback: not multi_arg_catch_all?(clauses, clause_tail_patterns),
            fallback_binds: fallback_binds,
            failure_kind: 2,
            failure_reason:
              {:{}, [],
               [
                 name,
                 arity,
                 [
                   {:__batata_unmatched__, [], nil}
                   | Enum.map(failure_tail_names, &{&1, [], nil})
                 ]
               ]}
          ],
          opts
        )
      )

    insert_return(return_value, ctx, block, module_env)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(Symbol.function(name, arity))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp validate_multi_arg_clauses!(arity, clauses) do
    Enum.map(clauses, fn %Frontend.Clause{patterns: patterns} ->
      unless length(patterns) == arity do
        raise Error, "clause arity mismatch for a multi-clause function"
      end

      {_first, tails} = Enum.split(patterns, 1)

      Enum.map(tails, &multi_arg_tail_pattern!/1)
    end)
  end

  defp multi_arg_tail_pattern!({:_, _, nil}), do: {:variable, nil}

  defp multi_arg_tail_pattern!({name, _, nil}) when is_atom(name),
    do: {:variable, name}

  defp multi_arg_tail_pattern!({:%, _, _} = pattern), do: {:term_pattern, pattern}

  defp multi_arg_tail_pattern!({:=, _, [left, right]} = pattern) do
    if struct_tail_pattern?(left) or struct_tail_pattern?(right),
      do: {:term_pattern, pattern},
      else: unsupported_multi_arg_tail_pattern!(pattern)
  end

  defp multi_arg_tail_pattern!({:__aliases__, _, parts} = pattern) when is_list(parts) do
    if parts != [] and Enum.all?(parts, &is_atom/1) do
      {:literal, Elixir.Module.concat(parts)}
    else
      unsupported_multi_arg_tail_pattern!(pattern)
    end
  end

  defp multi_arg_tail_pattern!(atom) when is_atom(atom), do: {:literal, atom}
  defp multi_arg_tail_pattern!(pattern), do: unsupported_multi_arg_tail_pattern!(pattern)

  defp unsupported_multi_arg_tail_pattern!(pattern) do
    raise Error,
          "multi-clause trailing arguments must be variables, wildcards, or " <>
            "compile-known atom literals or validated struct patterns: #{inspect(pattern)}"
  end

  defp tail_term_pattern?({kind, _}) when kind in [:literal, :term_pattern], do: true
  defp tail_term_pattern?(_pattern), do: false

  defp struct_tail_pattern?({:%, _, _}), do: true
  defp struct_tail_pattern?(_pattern), do: false

  defp tail_match(patterns, arguments, ctx, block, module_env) do
    schema = Map.get(module_env, @struct_schema_key)

    {conditions, bindings} =
      patterns
      |> Enum.zip(arguments)
      |> Enum.map_reduce([], fn
        {{:variable, nil}, _argument}, bindings ->
          {nil, bindings}

        {{:variable, name}, argument}, bindings ->
          {nil, [{name, argument} | bindings]}

        {{:literal, atom}, argument}, bindings ->
          {condition, []} = build_match(atom, argument, ctx, block, false, schema)
          {condition, bindings}

        {{:term_pattern, pattern}, argument}, bindings ->
          {condition, pattern_bindings} =
            build_match(pattern, argument, ctx, block, false, schema)

          {condition, Enum.reverse(pattern_bindings, bindings)}
      end)

    {combine(conditions, ctx, block), Enum.reverse(bindings)}
  end

  defp multi_arg_catch_all?(clauses, clause_tail_patterns) do
    clauses
    |> Enum.zip(clause_tail_patterns)
    |> Enum.any?(fn
      {%Frontend.Clause{patterns: [{name, _, nil} | _], guard_ast: nil}, tails}
      when is_atom(name) ->
        Enum.all?(tails, &match?({:variable, _}, &1))

      _clause ->
        false
    end)
  end

  defp tail_bindings(names, arguments) do
    names
    |> Enum.zip(arguments)
    |> Enum.reject(&(elem(&1, 0) == nil))
  end

  # Accumulator-scanner detection (the `reduce(binary, acc)` shape): a
  # two-argument function whose recursive clause matches fixed-width binary
  # head segments plus a rest and calls itself with the rest slice and an
  # accumulator step (`acc + delta`), and whose other clauses return the
  # accumulator unchanged.
  defp detect_accumulator_scanner(name, clauses) do
    parsed = Enum.map(clauses, &accumulator_scanner_clause(&1, name))

    with [%{delta: delta, head_width: width}] <-
           Enum.filter(parsed, &match?(%{kind: :recursive}, &1)),
         {:ok, acc_name} <- common_acc_name(parsed),
         true <- terminating_returns_acc?(parsed, acc_name) do
      {:ok, %{delta: delta, head_width: width, acc_name: acc_name}}
    else
      _ -> :skip
    end
  end

  defp accumulator_scanner_clause(
         %Frontend.Clause{patterns: [p1, acc_pat], guard_ast: nil, body_ast: body_ast},
         name
       ) do
    case binary_segments(p1) do
      {:ok, width, rest} ->
        case reduce_accumulator(body_ast, name, rest, acc_pat) do
          {:ok, delta} -> %{kind: :recursive, delta: delta, head_width: width, acc: acc_pat}
          :skip -> %{kind: :terminating, body: body_ast, acc: acc_pat}
        end

      :skip ->
        %{kind: :terminating, body: body_ast, acc: acc_pat}
    end
  end

  defp accumulator_scanner_clause(%Frontend.Clause{} = clause, _name) do
    %{kind: :terminating, body: clause.body_ast, acc: List.last(clause.patterns)}
  end

  defp reduce_accumulator({name, _, [var_ast, acc_expr]}, name, rest, acc_pat)
       when is_atom(name) do
    if var_name(var_ast) == var_name(rest) do
      acc_step(acc_expr, acc_pat)
    else
      :skip
    end
  end

  defp reduce_accumulator(_body_ast, _name, _rest, _acc_pat), do: :skip

  defp acc_step({acc, _, nil} = acc_ast, acc_pat) when is_atom(acc) do
    if var_name(acc_ast) == var_name(acc_pat), do: {:ok, 0}, else: :skip
  end

  defp acc_step({:+, _, [acc_ast, delta]}, acc_pat) when is_integer(delta) do
    if var_name(acc_ast) == var_name(acc_pat), do: {:ok, delta}, else: :skip
  end

  defp acc_step({:+, _, [delta, acc_ast]}, acc_pat) when is_integer(delta) do
    if var_name(acc_ast) == var_name(acc_pat), do: {:ok, delta}, else: :skip
  end

  defp acc_step({:-, _, [acc_ast, delta]}, acc_pat) when is_integer(delta) do
    if var_name(acc_ast) == var_name(acc_pat), do: {:ok, -delta}, else: :skip
  end

  defp acc_step(_acc_expr, _acc_pat), do: :skip

  defp common_acc_name(parsed) do
    case parsed |> Enum.map(&var_name(&1.acc)) |> Enum.uniq() do
      [acc_name] when is_atom(acc_name) -> {:ok, acc_name}
      _ -> :skip
    end
  end

  defp terminating_returns_acc?(parsed, acc_name) do
    parsed
    |> Enum.reject(&match?(%{kind: :recursive}, &1))
    |> Enum.all?(fn clause -> var_name(clause.body) == acc_name end)
  end

  # Cursor-loop optimization (expandable d95fd36/f62b38b route): a
  # tail-recursive binary scanner — one clause whose pattern is fixed-width
  # binary segments plus a rest, whose body accumulates `± delta` around the
  # self call, and whose other clauses return a common constant base —
  # compiles to a cf loop over the original binary with a cursor and
  # accumulator, avoiding per-step slice materialization and call overhead.
  defp detect_scanner(name, clauses) do
    parsed =
      Enum.map(clauses, fn clause ->
        scanner_clause(clause, name)
      end)

    with [%{delta: delta, head_width: width}] <-
           Enum.filter(parsed, &match?(%{kind: :recursive}, &1)),
         {:ok, base} <- common_base(parsed) do
      {:ok, %{base: base, delta: delta, head_width: width}}
    else
      _ -> :skip
    end
  end

  defp scanner_clause(
         %Frontend.Clause{patterns: [pattern], guard_ast: nil, body_ast: body_ast},
         name
       ) do
    case binary_segments(pattern) do
      {:ok, _width, nil} ->
        %{kind: :terminating, body: body_ast}

      {:ok, width, rest} ->
        case accumulator(body_ast, name, rest) do
          {:ok, delta} -> %{kind: :recursive, delta: delta, head_width: width}
          :skip -> %{kind: :terminating, body: body_ast}
        end

      :skip ->
        %{kind: :terminating, body: body_ast}
    end
  end

  defp scanner_clause(%Frontend.Clause{body_ast: body_ast}, _name) do
    %{kind: :terminating, body: body_ast}
  end

  defp binary_segments({:<<>>, _, segments}) do
    {bytes, rest} =
      Enum.split_while(segments, &(not match?({:"::", _, [_, {:binary, _, nil}]}, &1)))

    if Enum.all?(bytes, &byte_segment?/1) do
      parse_binary_rest(rest, length(bytes))
    else
      :skip
    end
  end

  defp binary_segments(_), do: :skip

  defp parse_binary_rest([], width), do: {:ok, width, nil}

  defp parse_binary_rest(
         [{:"::", _, [{name, _, nil} = rest_pattern, {:binary, _, nil}]}],
         width
       )
       when is_atom(name) and name != :_,
       do: {:ok, width, rest_pattern}

  defp parse_binary_rest(_rest, _width), do: :skip

  defp byte_segment?({:"::", _, [_, 8]}), do: true
  defp byte_segment?(pat) when is_integer(pat), do: true
  defp byte_segment?({_, _, nil}), do: true
  defp byte_segment?(_), do: false

  # `count(t)`, `delta + count(t)`, `count(t) + delta`, `count(t) - delta`
  # where `t` is the rest-segment bind.
  defp accumulator({name, _, [var_ast]}, name, rest) when is_atom(name) do
    if var_name(var_ast) == var_name(rest), do: {:ok, 0}, else: :skip
  end

  defp accumulator({:+, _, [delta, {name, _, [var_ast]}]}, name, rest)
       when is_integer(delta) and is_atom(name) do
    if var_name(var_ast) == var_name(rest), do: {:ok, delta}, else: :skip
  end

  defp accumulator({:+, _, [{name, _, [var_ast]}, delta]}, name, rest)
       when is_integer(delta) and is_atom(name) do
    if var_name(var_ast) == var_name(rest), do: {:ok, delta}, else: :skip
  end

  defp accumulator({:-, _, [{name, _, [var_ast]}, delta]}, name, rest)
       when is_integer(delta) and is_atom(name) do
    if var_name(var_ast) == var_name(rest), do: {:ok, -delta}, else: :skip
  end

  defp accumulator(_body_ast, _name, _rest), do: :skip

  defp var_name({name, _, nil}) when is_atom(name), do: name
  defp var_name(_), do: nil

  defp common_base(parsed) do
    bases =
      parsed
      |> Enum.reject(&match?(%{kind: :recursive}, &1))
      |> Enum.map(&terminator_base(&1.body))

    case Enum.uniq(bases) do
      [base] when is_integer(base) -> {:ok, base}
      _ -> :skip
    end
  end

  defp terminator_base(body) when is_integer(body), do: body
  defp terminator_base(_body), do: :skip

  defp lift_scanner_loop(
         name,
         %{base: base, delta: delta, head_width: width},
         ctx,
         ip,
         budget,
         batch_size
       ) do
    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)
    i64 = integer_type(ctx)

    block = MLIR.Block.create([i64], [loc])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg] = block |> Walker.arguments() |> Enum.to_list()

    base_val = lit(base, ctx, block)
    acc_result = emit_cursor_while(block, arg, base_val, width, delta, ctx, budget, batch_size)
    create_op("ex.return", [acc_result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(Symbol.function(name, 1))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp lift_reduce_loop(name, %{delta: delta, head_width: width}, ctx, ip, budget, batch_size) do
    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)

    block = MLIR.Block.create([integer_type(ctx), integer_type(ctx)], [loc, loc])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg, acc0] = block |> Walker.arguments() |> Enum.to_list()

    acc_result = emit_cursor_while(block, arg, acc0, width, delta, ctx, budget, batch_size)
    create_op("ex.return", [acc_result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(Symbol.function(name, 2))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  # Stable native trampoline invoked by the Zig worker pool. Runtime claim
  # establishes the current actor before this function is entered; the pid
  # argument keeps the callback ABI explicit even though dispatch reads the
  # current process entry from Runtime.
  defp lift_actor_step(ctx, ip, has_dispatch) do
    i64 = integer_type(ctx)
    dyn = ex_type("term", ctx)
    i1 = MLIR.Type.i1()
    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([i64], [MLIR.Location.unknown(ctx: ctx)])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    entry = create_op("ex.current_entry", [], [i64], ctx, block)
    is_main = create_op("arith.trunci", [cmp(entry, 0, "eq", ctx, block)], [i1], ctx, block)

    result =
      build_scf_if(
        is_main,
        ctx,
        block,
        [i64],
        fn b -> [unbox(call_entry(ctx, b), ctx, b)] end,
        fn b ->
          if has_dispatch do
            entry_word = create_op("ex.to_word", [entry], [dyn], ctx, b)

            [
              create_op(
                "ex.apply",
                [
                  entry_word,
                  arg_count: MLIR.Attribute.integer(MLIR.Type.i64(), 0),
                  operandSegmentSizes: segment_sizes([1, 0, 0, 0, 0])
                ],
                [i64],
                ctx,
                b
              )
            ]
          else
            [unbox(call_entry(ctx, b), ctx, b)]
          end
        end
      )
      |> hd()

    create_op("ex.return", [result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string("__batata_actor_step")],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  # Even scalar programs run behind a host entry that owns an explicit native
  # runtime. This keeps JIT and AOT executions isolated without relying on the
  # compatibility runtime associated with an OS thread.
  defp lift_execution_driver(entry_name, ctx, ip, process_cap) do
    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    runtime = enter_runtime(ctx, block)

    create_op(
      "ex.process_table_reset",
      [lit(process_cap, ctx, block)],
      [integer_type(ctx)],
      ctx,
      block
    )

    result = call_entry(ctx, block) |> unbox(ctx, block)
    handle = retain_result(runtime, result, ctx, block)
    create_op("ex.return", [handle, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(entry_name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp enter_runtime(ctx, block) do
    i64 = integer_type(ctx)
    runtime = create_op("ex.runtime_create", [], [i64], ctx, block)
    create_op("ex.runtime_enter", [runtime], [i64], ctx, block)
    runtime
  end

  defp retain_result(runtime, result, ctx, block) do
    i64 = integer_type(ctx)
    handle = create_op("ex.result_create", [runtime, result], [i64], ctx, block)
    create_op("ex.runtime_leave", [], [i64], ctx, block)
    handle
  end

  defp lift_parallel_driver(entry_name, ctx, ip, workers, process_cap) do
    i64 = integer_type(ctx)
    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    runtime = enter_runtime(ctx, block)
    create_op("ex.process_table_reset", [lit(process_cap, ctx, block)], [i64], ctx, block)

    dispatcher =
      create_op(
        "ex.func_addr",
        [sym_name: MLIR.Attribute.string("__batata_actor_step")],
        [MLIR.Type.function([i64], [i64])],
        ctx,
        block
      )

    result =
      create_op(
        "ex.worker_run",
        [lit(workers, ctx, block), dispatcher],
        [i64],
        ctx,
        block
      )

    handle = retain_result(runtime, result, ctx, block)
    create_op("ex.return", [handle, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(entry_name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  # The scheduler driver (#35 slice 5): runs the compiled entry as process 0,
  # then round-robins every runnable process (process 0 plus spawned
  # closures) until none remain. A process that returns with a pending
  # continuation (budget exhausted) stays runnable and is resumed on a later
  # round from its saved loop state; a completed process is parked with its
  # result. The driver returns the entry's final result.
  defp lift_driver(entry_name, ctx, ip, _budget, has_dispatch, process_cap) do
    i64 = integer_type(ctx)
    dyn = ex_type("term", ctx)
    i1 = MLIR.Type.i1()

    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    runtime = enter_runtime(ctx, block)

    # Each program run starts with a fresh actor table at the configured cap.
    create_op("ex.process_table_reset", [lit(process_cap, ctx, block)], [i64], ctx, block)

    # First slice of process 0: run the compiled entry once.
    r0 = call_entry(ctx, block)
    p0 = create_op("ex.cont_pending", [], [i64], ctx, block)
    c0_i1 = create_op("arith.trunci", [cmp(p0, 0, "eq", ctx, block)], [i1], ctx, block)

    # Park process 0 when it completed on the first slice.
    build_scf_if(
      c0_i1,
      ctx,
      block,
      [],
      fn b ->
        create_op("ex.process_done", [unbox(r0, ctx, b)], [i64], ctx, b)
        []
      end,
      fn _b -> [] end
    )

    r0_i64 = unbox(r0, ctx, block)
    zero = lit(0, ctx, block)

    main_res0 =
      build_scf_if(c0_i1, ctx, block, [i64], fn _b -> [r0_i64] end, fn _b -> [zero] end)

    main_res0 = hd(main_res0)

    # Scheduler loop: while any process is runnable, switch to the next one
    # and run its entry.
    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create([i64], [MLIR.Location.unknown(ctx: ctx)])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create([i64], [MLIR.Location.unknown(ctx: ctx)])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_main_res] = before_block |> Walker.arguments() |> Enum.to_list()
    runnable = create_op("ex.processes_runnable", [], [i64], ctx, before_block)
    cond = cmp(runnable, 0, "sgt", ctx, before_block)
    cond_i1 = create_op("arith.trunci", [cond], [i1], ctx, before_block)
    create_op("scf.condition", [cond_i1, b_main_res], [], ctx, before_block)

    [a_main_res] = after_block |> Walker.arguments() |> Enum.to_list()
    _pid = create_op("ex.schedule_next", [], [i64], ctx, after_block)
    entry = create_op("ex.current_entry", [], [i64], ctx, after_block)

    is_main =
      create_op("arith.trunci", [cmp(entry, 0, "eq", ctx, after_block)], [i1], ctx, after_block)

    # Run the current process's entry: the compiled entry for process 0, or
    # the spawned closure through the closure dispatch. Both branches yield
    # i64 so the select stays scalar through conversion.
    res =
      build_scf_if(
        is_main,
        ctx,
        after_block,
        [i64],
        fn b ->
          [unbox(call_entry(ctx, b), ctx, b)]
        end,
        fn b ->
          # Spawned entries are closures dispatched through `__fn_dispatch`;
          # without anonymous functions the branch is unreachable (schedule_next
          # always returns process 0), so fall back to the compiled entry.
          if has_dispatch do
            entry_word = create_op("ex.to_word", [entry], [dyn], ctx, b)

            [
              create_op(
                "ex.apply",
                [
                  entry_word,
                  arg_count: MLIR.Attribute.integer(MLIR.Type.i64(), 0),
                  operandSegmentSizes: segment_sizes([1, 0, 0, 0, 0])
                ],
                [i64],
                ctx,
                b
              )
            ]
          else
            [unbox(call_entry(ctx, b), ctx, b)]
          end
        end
      )

    res = hd(res)
    pending = create_op("ex.cont_pending", [], [i64], ctx, after_block)

    completed_i1 =
      create_op("arith.trunci", [cmp(pending, 0, "eq", ctx, after_block)], [i1], ctx, after_block)

    build_scf_if(
      completed_i1,
      ctx,
      after_block,
      [],
      fn b ->
        create_op("ex.process_done", [res], [i64], ctx, b)
        []
      end,
      fn _b -> [] end
    )

    update_i1 = create_op("arith.andi", [completed_i1, is_main], [i1], ctx, after_block)

    new_main =
      build_scf_if(update_i1, ctx, after_block, [i64], fn _b -> [res] end, fn _b ->
        [a_main_res]
      end)

    create_op("scf.yield", [hd(new_main)], [], ctx, after_block)

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments: [main_res0],
        results: [i64],
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    final = while_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
    handle = retain_result(runtime, final, ctx, block)
    create_op("ex.return", [handle, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(entry_name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  @result_accessors [
    {"__batata_result_destroy", "ex.result_destroy", 1},
    {"__batata_result_root_kind", "ex.result_root_kind", 1},
    {"__batata_result_root_word", "ex.result_root_word", 1},
    {"__batata_result_exception_kind", "ex.result_exception_kind", 1},
    {"__batata_result_exception_reason", "ex.result_exception_reason", 1},
    {"__batata_result_term_kind", "ex.result_term_kind", 2},
    {"__batata_result_term_length", "ex.result_term_length", 2},
    {"__batata_result_term_get", "ex.result_term_get", 3},
    {"__batata_term_export", "ex.term_export", 2},
    {"__batata_term_import", "ex.term_import", 2},
    {"__batata_exported_clone", "ex.exported_clone", 1},
    {"__batata_exported_destroy", "ex.exported_destroy", 1},
    {"__batata_exported_length", "ex.exported_length", 1},
    {"__batata_exported_get", "ex.exported_get", 2},
    {"__batata_term_handle_export", "ex.term_handle_export", 1},
    {"__batata_term_handle_destroy", "ex.term_handle_destroy", 1}
  ]

  # Stable C/JIT entry points keep host materialization independent of the
  # runtime library's platform-specific symbol loading rules.
  defp lift_result_accessors(ctx, ip) do
    Enum.each(@result_accessors, fn {name, op_name, arity} ->
      i64 = integer_type(ctx)
      region = MLIR.CAPI.mlirRegionCreate()
      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), arity)
      block = MLIR.Block.create(List.duplicate(i64, arity), locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
      args = block |> Walker.arguments() |> Enum.to_list()
      result = create_op(op_name, args, [i64], ctx, block)
      create_op("ex.return", [result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

      %Beaver.SSA{
        op: "ex.func",
        ip: ip,
        ctx: ctx,
        arguments: [sym_name: MLIR.Attribute.string(name)],
        results: [],
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()
    end)
  end

  # Calls the compiled entry (`__batata_entry`) with no arguments.
  defp call_entry(ctx, block) do
    create_op(
      "ex.call",
      [
        callee: MLIR.Attribute.string("__batata_entry"),
        arity: MLIR.Attribute.integer(MLIR.Type.i64(), 0),
        operandSegmentSizes: segment_sizes(arg_segment_sizes(0))
      ],
      [ex_type("term", ctx)],
      ctx,
      block
    )
  end

  defp unbox(value, ctx, block) do
    create_op("ex.unbox", [value], [integer_type(ctx)], ctx, block)
  end

  # Builds an `scf.if` with two regions; each branch function appends its
  # ops and returns the `scf.yield` operands. Returns the op results.
  defp build_scf_if(cond_i1, ctx, block, result_types, then_fn, else_fn) do
    then_region = MLIR.CAPI.mlirRegionCreate()
    then_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(then_region, then_block)
    then_operands = then_fn.(then_block)
    create_op("scf.yield", then_operands, [], ctx, then_block)

    else_region = MLIR.CAPI.mlirRegionCreate()
    else_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(else_region, else_block)
    else_operands = else_fn.(else_block)
    create_op("scf.yield", else_operands, [], ctx, else_block)

    if_op =
      %Beaver.SSA{
        op: "scf.if",
        ip: block,
        ctx: ctx,
        arguments: [cond_i1],
        results: result_types,
        loc: MLIR.Location.unknown(),
        filler: fn -> [then_region, else_region] end
      }
      |> MLIR.Operation.create()

    if_op |> MLIR.Operation.results() |> Enum.to_list()
  end

  # scf.while keeps the ex.func body to a single block: the before region
  # carries (arg, acc, cursor) and conditions on the next head segment
  # existing; the after region advances the accumulator and cursor.
  defp emit_cursor_while(block, arg, acc, width, delta, ctx, budget, batch_size) do
    i64 = integer_type(ctx)

    if budget == nil do
      # Without a budget the loop is a plain 3-value cursor loop: no
      # countdown, no tick (#41 fast path).
      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)
      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_arg, b_acc, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
      word = create_op("ex.to_word", [b_arg], [ex_type("term", ctx)], ctx, before_block)
      len = create_op("ex.binary_length", [word], [i64], ctx, before_block)

      next_cursor =
        create_op("ex.add", [b_cursor, lit(width, ctx, before_block)], [i64], ctx, before_block)

      cond = cmp(len, next_cursor, "sge", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)
      create_op("scf.condition", [cond_i1, b_arg, b_acc, b_cursor], [], ctx, before_block)

      [a_arg, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()

      acc_next =
        create_op("ex.add", [a_acc, lit(delta, ctx, after_block)], [i64], ctx, after_block)

      cursor_next =
        create_op("ex.add", [a_cursor, lit(width, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_arg, acc_next, cursor_next], [], ctx, after_block)

      {state_arg, state_acc, state_cursor} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            {arg, acc, lit(0, ctx, b)}
          end,
          batch_size
        )

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_arg, state_acc, state_cursor],
          results: [i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
    else
      # Budgeted: 4-value state (arg, acc, cursor, countdown); the countdown
      # is reset per slice (see resumable_loop_state) so it never needs a
      # runtime continuation slot (#41).
      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 4)
      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_arg, b_acc, b_cursor, b_countdown] =
        before_block |> Walker.arguments() |> Enum.to_list()

      word = create_op("ex.to_word", [b_arg], [ex_type("term", ctx)], ctx, before_block)
      len = create_op("ex.binary_length", [word], [i64], ctx, before_block)

      next_cursor =
        create_op("ex.add", [b_cursor, lit(width, ctx, before_block)], [i64], ctx, before_block)

      cond = cmp(len, next_cursor, "sge", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)

      {budget_cond, next_countdown} =
        inject_reduction_tick(
          before_block,
          ctx,
          cond_i1,
          budget,
          {b_arg, b_acc, b_cursor, b_countdown},
          false,
          batch_size
        )

      create_op(
        "scf.condition",
        [budget_cond, b_arg, b_acc, b_cursor, next_countdown],
        [],
        ctx,
        before_block
      )

      [a_arg, a_acc, a_cursor, a_countdown] =
        after_block |> Walker.arguments() |> Enum.to_list()

      acc_next =
        create_op("ex.add", [a_acc, lit(delta, ctx, after_block)], [i64], ctx, after_block)

      cursor_next =
        create_op("ex.add", [a_cursor, lit(width, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_arg, acc_next, cursor_next, a_countdown], [], ctx, after_block)

      {state_arg, state_acc, state_cursor, state_countdown} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            {arg, acc, lit(0, ctx, b)}
          end,
          batch_size
        )

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_arg, state_acc, state_cursor, state_countdown],
          results: [i64, i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
    end
  end

  # `Enum.reduce/3` with a `fn item, acc -> item + acc end` reducer compiles
  # to a cursor loop over the list: carries (list, acc, cursor), reads each
  # element via `ex.list_get`, untags it, and accumulates.
  defp lift_enum_sum_loop(list_word, acc0, ctx, block, budget, batch_size) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.add", :acc_first}, ctx, block, budget, batch_size)
  end

  # #35 slice 2/3: charge one reduction per loop iteration (the scf.while
  # before region runs once per iteration). Without a budget the tick is a
  # no-op. With a budget, an exhausted budget saves the cursor-loop
  # continuation (arg, acc, cursor) to the runtime and records a yield; the
  # condition becomes false so the loop exits and the entry returns control
  # to the scheduler driver, which resumes the saved state later (#35 slice 5).
  # #35 slice 2/3: charge reductions on the scf.while back edge. #41 batching:
  # the loop carries a pure-arith countdown iter_arg; only when it reaches
  # zero does the before region call `ex.reduction_tick(batch)` once (charging
  # the whole batch) and reset the countdown, so the clock check is out of the
  # per-iteration hot path. Returns `{budget_cond, next_countdown}`; without a
  # budget the loop condition passes through and no countdown is produced.
  defp inject_reduction_tick(
         _before_block,
         _ctx,
         cond_i1,
         nil,
         _state,
         _receive?,
         _batch_size
       ),
       do: {cond_i1, nil}

  defp inject_reduction_tick(
         before_block,
         ctx,
         cond_i1,
         _budget,
         {arg, acc, cursor, countdown},
         receive?,
         batch_size
       ) do
    i64 = integer_type(ctx)
    i1 = MLIR.Type.i1()

    countdown_next =
      create_op("ex.sub", [countdown, lit(1, ctx, before_block)], [i64], ctx, before_block)

    at_batch_i1 =
      create_op(
        "arith.trunci",
        [cmp(countdown_next, 0, "eq", ctx, before_block)],
        [MLIR.Type.i1()],
        ctx,
        before_block
      )

    [budget_cond, next_countdown] =
      build_scf_if(
        at_batch_i1,
        ctx,
        before_block,
        [i1, i64],
        fn b ->
          ticked = create_op("ex.reduction_tick", [lit(batch_size, ctx, b)], [i64], ctx, b)

          exhausted_i1 =
            create_op(
              "arith.trunci",
              [cmp(ticked, 0, "ne", ctx, b)],
              [MLIR.Type.i1()],
              ctx,
              b
            )

          should_yield_i1 =
            create_op("arith.andi", [cond_i1, exhausted_i1], [MLIR.Type.i1()], ctx, b)

          build_scf_if(
            should_yield_i1,
            ctx,
            b,
            [i1, i64],
            fn tb ->
              # Selective-receive scans save a receive-type continuation so a
              # message arrival invalidates it (epoch wiring); cursor loops save
              # a loop-type continuation that message arrival must not affect.
              create_op(continuation_save_op(receive?), [arg, acc, cursor], [i64], ctx, tb)
              create_op("ex.yield_mark", [], [i64], ctx, tb)

              false_i1 =
                create_op("arith.trunci", [lit(0, ctx, tb)], [MLIR.Type.i1()], ctx, tb)

              [false_i1, lit(0, ctx, tb)]
            end,
            fn tb ->
              [cond_i1, lit(batch_size, ctx, tb)]
            end
          )
        end,
        fn _b ->
          [cond_i1, countdown_next]
        end
      )

    {budget_cond, next_countdown}
  end

  defp continuation_save_op(true), do: "ex.receive_cont_save"
  defp continuation_save_op(false), do: "ex.cont_save"

  # Computes the initial (arg, acc, cursor) state of a cursor loop. Without a
  # budget the loop runs the fresh init inline (single invocation). With a
  # budget the loop is resumable: each invocation starts by resetting the
  # process's reduction clock (a new slice) and checks for a saved
  # continuation — when one is pending at the current epoch, the state is
  # restored from the runtime so the loop resumes where it yielded; otherwise
  # the fresh init runs.
  # #41 batching: with a budget the loop state gains a fourth countdown
  # iter_arg (batch_size..0). The countdown is a derived quantity — each slice
  # restarts it at batch_size — so it does not need a runtime continuation
  # slot: the resume branch loads (arg, acc, cursor) and restarts the
  # countdown, and the fresh branch does the same alongside the fresh init.
  defp resumable_loop_state(block, ctx, budget, fresh_init, batch_size \\ nil) do
    if budget == nil do
      fresh_init.(block)
    else
      i64 = integer_type(ctx)
      create_op("ex.clock_init", [lit(budget, ctx, block)], [i64], ctx, block)
      batch_size = batch_size || budget

      # Resume the saved cursor even when message delivery invalidated its
      # epoch. The state remains positionally valid and the receive loop reads
      # the live mailbox length; restarting would repeat pre-loop effects.
      active = create_op("ex.cont_active", [], [i64], ctx, block)

      active_i1 =
        create_op("arith.trunci", [active], [MLIR.Type.i1()], ctx, block)

      resume_region = MLIR.CAPI.mlirRegionCreate()
      resume_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(resume_region, resume_block)
      arg_v = create_op("ex.cont_load_arg", [], [i64], ctx, resume_block)
      acc_v = create_op("ex.cont_load_acc", [], [i64], ctx, resume_block)
      cursor_v = create_op("ex.cont_load_cursor", [], [i64], ctx, resume_block)
      countdown_v = lit(batch_size, ctx, resume_block)
      # The continuation is consumed by the resume: a completed loop must not
      # read as still pending (the driver parks a process only when the entry
      # returns with no pending continuation).
      create_op("ex.cont_clear", [], [i64], ctx, resume_block)
      create_op("scf.yield", [arg_v, acc_v, cursor_v, countdown_v], [], ctx, resume_block)

      fresh_region = MLIR.CAPI.mlirRegionCreate()
      fresh_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(fresh_region, fresh_block)
      {arg_f, acc_f, cursor_f} = fresh_init.(fresh_block)
      countdown_f = lit(batch_size, ctx, fresh_block)
      create_op("scf.yield", [arg_f, acc_f, cursor_f, countdown_f], [], ctx, fresh_block)

      if_op =
        %Beaver.SSA{
          op: "scf.if",
          ip: block,
          ctx: ctx,
          arguments: [active_i1],
          results: [i64, i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [resume_region, fresh_region] end
        }
        |> MLIR.Operation.create()

      [arg, acc, cursor, countdown] = if_op |> MLIR.Operation.results() |> Enum.to_list()
      {arg, acc, cursor, countdown}
    end
  end

  defp lift_enum_product_loop(list_word, acc0, ctx, block, budget, batch_size) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.mul", :acc_first}, ctx, block, budget, batch_size)
  end

  defp lift_enum_subtract_loop(list_word, acc0, order, ctx, block, budget, batch_size) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.sub", order}, ctx, block, budget, batch_size)
  end

  defp lift_enum_cursor_loop(
         list_word,
         acc0,
         {accumulate_op, order},
         ctx,
         block,
         budget,
         batch_size
       ) do
    i64 = integer_type(ctx)

    if budget == nil do
      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)

      {state_list, state_acc, state_cursor} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
            {list_i64, acc0, lit(0, ctx, b)}
          end,
          batch_size
        )

      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_list, b_acc, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
      b_word = create_op("ex.to_word", [b_list], [ex_type("term", ctx)], ctx, before_block)
      len = create_op("ex.list_length", [b_word], [i64], ctx, before_block)
      cond = cmp(b_cursor, len, "slt", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)
      create_op("scf.condition", [cond_i1, b_list, b_acc, b_cursor], [], ctx, before_block)

      [a_list, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
      a_word = create_op("ex.to_word", [a_list], [ex_type("term", ctx)], ctx, after_block)

      item =
        create_op("ex.list_get", [a_word, a_cursor], [ex_type("term", ctx)], ctx, after_block)

      item_i64 = create_op("ex.to_int", [item], [i64], ctx, after_block)

      acc_next =
        case order do
          :acc_first -> create_op(accumulate_op, [a_acc, item_i64], [i64], ctx, after_block)
          :item_first -> create_op(accumulate_op, [item_i64, a_acc], [i64], ctx, after_block)
        end

      cursor_next =
        create_op("ex.add", [a_cursor, lit(1, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_list, acc_next, cursor_next], [], ctx, after_block)

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_list, state_acc, state_cursor],
          results: [i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
    else
      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 4)

      {state_list, state_acc, state_cursor, state_countdown} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
            {list_i64, acc0, lit(0, ctx, b)}
          end,
          batch_size
        )

      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_list, b_acc, b_cursor, b_countdown] =
        before_block |> Walker.arguments() |> Enum.to_list()

      b_word = create_op("ex.to_word", [b_list], [ex_type("term", ctx)], ctx, before_block)
      len = create_op("ex.list_length", [b_word], [i64], ctx, before_block)
      cond = cmp(b_cursor, len, "slt", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)

      {budget_cond, next_countdown} =
        inject_reduction_tick(
          before_block,
          ctx,
          cond_i1,
          budget,
          {b_list, b_acc, b_cursor, b_countdown},
          false,
          batch_size
        )

      create_op(
        "scf.condition",
        [budget_cond, b_list, b_acc, b_cursor, next_countdown],
        [],
        ctx,
        before_block
      )

      [a_list, a_acc, a_cursor, a_countdown] =
        after_block |> Walker.arguments() |> Enum.to_list()

      a_word = create_op("ex.to_word", [a_list], [ex_type("term", ctx)], ctx, after_block)

      item =
        create_op("ex.list_get", [a_word, a_cursor], [ex_type("term", ctx)], ctx, after_block)

      item_i64 = create_op("ex.to_int", [item], [i64], ctx, after_block)

      acc_next =
        case order do
          :acc_first -> create_op(accumulate_op, [a_acc, item_i64], [i64], ctx, after_block)
          :item_first -> create_op(accumulate_op, [item_i64, a_acc], [i64], ctx, after_block)
        end

      cursor_next =
        create_op("ex.add", [a_cursor, lit(1, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_list, acc_next, cursor_next, a_countdown], [], ctx, after_block)

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_list, state_acc, state_cursor, state_countdown],
          results: [i64, i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
    end
  end

  # Combination reducer over a list literal: the cursor loop's after region
  # compiles the reducer body with the item (untagged) and accumulator bound
  # to the loop variables.

  # Tag-dispatched enumerable reduce through the Zig runtime (continuation
  # 1 = sum), used when the enumerable is not a list literal.
  defp lift_enum_reduce_runtime(enumerable_word, acc0, continuation, ctx, block) do
    i64 = integer_type(ctx)

    create_op(
      "ex.enumerable_reduce",
      [enumerable_word, acc0, lit(continuation, ctx, block)],
      [i64],
      ctx,
      block
    )
  end

  # Closure-shaped enumerable reduce with a captured scalar (continuation
  # 13 = sum with capture).
  defp lift_enum_reduce_capture(
         enumerable_word,
         acc0,
         capture_i64,
         ctx,
         block,
         continuation \\ 13
       ) do
    i64 = integer_type(ctx)

    create_op(
      "ex.enumerable_reduce_c",
      [enumerable_word, acc0, lit(continuation, ctx, block), capture_i64],
      [i64],
      ctx,
      block
    )
  end

  # Inclusive integer range reduce through the runtime (continuation table).
  defp lift_enum_range_reduce(start, stop, acc0, continuation, ctx, block) do
    i64 = integer_type(ctx)

    create_op(
      "ex.enumerable_reduce_range",
      [start, stop, acc0, lit(continuation, ctx, block)],
      [i64],
      ctx,
      block
    )
  end

  defp range_ast?({:.., _, [start, stop]}), do: {true, start, stop}
  defp range_ast?(_ast), do: false

  defp range_continuation(:sum), do: 1
  defp range_continuation(:product), do: 6
  defp range_continuation(:subtract_acc_first), do: 7
  defp range_continuation(:subtract_item_first), do: 8
  defp range_continuation(:div_acc_first), do: 9
  defp range_continuation(:div_item_first), do: 10
  defp range_continuation(:rem_acc_first), do: 11
  defp range_continuation(:rem_item_first), do: 12
  defp range_continuation(:return_acc), do: 2
  defp range_continuation(_pattern), do: nil

  # `Enum.map/2` with a constant mapper (`fn _x -> c end`) compiles to a
  # descending cursor loop that conses the constant onto the accumulator,
  # preserving list order without a reverse.
  defp lift_enum_const_map(list_word, value, ctx, block, budget, batch_size) do
    lift_enum_map_loop(
      list_word,
      ctx,
      block,
      fn _item, b -> lit(value, ctx, b) end,
      budget,
      batch_size
    )
  end

  # `Enum.map/2` with a capture-add mapper (`fn x -> x + c end`) compiles to
  # the same descending loop, adding the captured scalar to each element.
  defp lift_enum_capture_map(list_word, capture_i64, ctx, block, budget, batch_size) do
    lift_enum_map_loop(
      list_word,
      ctx,
      block,
      fn item, b ->
        create_op("ex.add", [item, capture_i64], [integer_type(ctx)], ctx, b)
      end,
      budget,
      batch_size
    )
  end

  defp lift_enum_map_loop(list_word, ctx, block, mapper_fun, budget, batch_size) do
    i64 = integer_type(ctx)

    if budget == nil do
      {state_list, state_acc, state_cursor} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
            len = create_op("ex.list_length", [list_word], [i64], ctx, b)
            cursor0 = create_op("ex.sub", [len, lit(1, ctx, b)], [i64], ctx, b)
            nil_dyn = create_term_op("ex.list", [], ctx, b)
            nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, b)
            {list_i64, nil_i64, cursor0}
          end,
          batch_size
        )

      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)
      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_list, b_acc, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
      cond = cmp(b_cursor, lit(0, ctx, before_block), "sge", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)
      create_op("scf.condition", [cond_i1, b_list, b_acc, b_cursor], [], ctx, before_block)

      [a_list, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
      a_word = create_op("ex.to_word", [a_list], [ex_type("term", ctx)], ctx, after_block)

      item =
        create_op("ex.list_get", [a_word, a_cursor], [ex_type("term", ctx)], ctx, after_block)

      item_i64 = create_op("ex.to_int", [item], [i64], ctx, after_block)
      mapped = mapper_fun.(item_i64, after_block)
      mapped_term = box_term(mapped, ctx, after_block)
      acc_dyn = create_op("ex.to_word", [a_acc], [ex_type("term", ctx)], ctx, after_block)

      acc_next_dyn =
        create_op(
          "ex.list_cons",
          [mapped_term, acc_dyn],
          [ex_type("term", ctx)],
          ctx,
          after_block
        )

      acc_next = create_op("ex.unbox", [acc_next_dyn], [i64], ctx, after_block)

      cursor_next =
        create_op("ex.sub", [a_cursor, lit(1, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_list, acc_next, cursor_next], [], ctx, after_block)

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_list, state_acc, state_cursor],
          results: [i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      acc_i64 = while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
      create_op("ex.to_word", [acc_i64], [ex_type("term", ctx)], ctx, block)
    else
      {state_list, state_acc, state_cursor, state_countdown} =
        resumable_loop_state(
          block,
          ctx,
          budget,
          fn b ->
            list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
            len = create_op("ex.list_length", [list_word], [i64], ctx, b)
            cursor0 = create_op("ex.sub", [len, lit(1, ctx, b)], [i64], ctx, b)
            nil_dyn = create_term_op("ex.list", [], ctx, b)
            nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, b)
            {list_i64, nil_i64, cursor0}
          end,
          batch_size
        )

      locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 4)
      before = MLIR.CAPI.mlirRegionCreate()
      before_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

      after_region = MLIR.CAPI.mlirRegionCreate()
      after_block = MLIR.Block.create([i64, i64, i64, i64], locs)
      MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

      [b_list, b_acc, b_cursor, b_countdown] =
        before_block |> Walker.arguments() |> Enum.to_list()

      cond = cmp(b_cursor, lit(0, ctx, before_block), "sge", ctx, before_block)
      cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)

      {budget_cond, next_countdown} =
        inject_reduction_tick(
          before_block,
          ctx,
          cond_i1,
          budget,
          {b_list, b_acc, b_cursor, b_countdown},
          false,
          batch_size
        )

      create_op(
        "scf.condition",
        [budget_cond, b_list, b_acc, b_cursor, next_countdown],
        [],
        ctx,
        before_block
      )

      [a_list, a_acc, a_cursor, a_countdown] =
        after_block |> Walker.arguments() |> Enum.to_list()

      a_word = create_op("ex.to_word", [a_list], [ex_type("term", ctx)], ctx, after_block)

      item =
        create_op("ex.list_get", [a_word, a_cursor], [ex_type("term", ctx)], ctx, after_block)

      item_i64 = create_op("ex.to_int", [item], [i64], ctx, after_block)
      mapped = mapper_fun.(item_i64, after_block)
      mapped_term = box_term(mapped, ctx, after_block)
      acc_dyn = create_op("ex.to_word", [a_acc], [ex_type("term", ctx)], ctx, after_block)

      acc_next_dyn =
        create_op(
          "ex.list_cons",
          [mapped_term, acc_dyn],
          [ex_type("term", ctx)],
          ctx,
          after_block
        )

      acc_next = create_op("ex.unbox", [acc_next_dyn], [i64], ctx, after_block)

      cursor_next =
        create_op("ex.sub", [a_cursor, lit(1, ctx, after_block)], [i64], ctx, after_block)

      create_op("scf.yield", [a_list, acc_next, cursor_next, a_countdown], [], ctx, after_block)

      while_op =
        %Beaver.SSA{
          op: "scf.while",
          ip: block,
          ctx: ctx,
          arguments: [state_list, state_acc, state_cursor, state_countdown],
          results: [i64, i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [before, after_region] end
        }
        |> MLIR.Operation.create()

      acc_i64 = while_op |> MLIR.Operation.results() |> Enum.to_list() |> Enum.at(1)
      create_op("ex.to_word", [acc_i64], [ex_type("term", ctx)], ctx, block)
    end
  end

  defp enum_capture_i64(capture, ctx, block) do
    if term_operand?(capture) do
      create_op("ex.to_int", [capture], [integer_type(ctx)], ctx, block)
    else
      capture
    end
  end

  defp lift_block(expressions, ctx, block, env) do
    lift_block_gated(expressions, ctx, block, env)
  end

  # Lifts a block of expressions. When an expression's lift created a
  # budgeted cursor loop, the continuation is gated: a yielded slice returns
  # the loop's partial result immediately, and the remaining body (receives,
  # further computation) runs only once the loop completed, so post-loop side
  # effects never repeat across scheduler slices (#35 slice 5).
  defp lift_block_gated([], _ctx, _block, env), do: {nil, env}

  defp lift_block_gated([expression | rest], ctx, block, env) do
    {value, env} = lift_expr(expression, ctx, block, env)

    env
    |> Map.pop(:__yield_gate__)
    |> continue_lift_block(value, rest, ctx, block)
  end

  defp continue_lift_block({_yield_gate, env}, value, [], _ctx, _block), do: {value, env}

  defp continue_lift_block({nil, env}, _value, rest, ctx, block),
    do: lift_block_gated(rest, ctx, block, env)

  defp continue_lift_block({{pending_i1, loop_result}, env}, _value, rest, ctx, block) do
    gate_value =
      build_scf_if(
        pending_i1,
        ctx,
        block,
        [integer_type(ctx)],
        fn _block -> [loop_result] end,
        fn rest_block ->
          {rest_value, _rest_env} = lift_block_gated(rest, ctx, rest_block, env)
          [rest_value]
        end
      )
      |> hd()

    {gate_value, env}
  end

  # Records that a budgeted cursor loop was just lifted: the caller computes
  # the post-loop continuation check so `lift_block_gated` can gate the rest
  # of the body on it.
  defp mark_yield_gate(budget, loop?, value, ctx, block, env) do
    if budget != nil and loop? do
      pending = create_op("ex.cont_pending", [], [integer_type(ctx)], ctx, block)

      pending_i1 =
        create_op("arith.trunci", [pending], [MLIR.Type.i1()], ctx, block)

      {value, Map.put(env, :__yield_gate__, {pending_i1, value})}
    else
      {value, env}
    end
  end

  defp lift_expr(integer, ctx, block, env) when is_integer(integer) do
    validate_scalar_integer_literal!(integer)

    {
      create_op(
        "ex.lit",
        [value: MLIR.Attribute.integer(MLIR.Type.i64(), integer)],
        [MLIR.Type.i64()],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr(float, ctx, block, env) when is_float(float) do
    <<bits::signed-64-native>> = <<float::float-64-native>>

    {
      create_op(
        "ex.float_lit",
        [lit(bits, ctx, block)],
        [ex_type("term", ctx)],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr({:-, _, [float]}, ctx, block, env) when is_float(float),
    do: lift_expr(-float, ctx, block, env)

  defp lift_expr({:+, _, [float]}, ctx, block, env) when is_float(float),
    do: lift_expr(float, ctx, block, env)

  # Elixir keeps signed boundary literals as unary operator AST. Fold them
  # before generic call lifting so the minimum tagged integer remains
  # representable while values outside the term domain fail deterministically.
  defp lift_expr({:-, _, [integer]}, ctx, block, env) when is_integer(integer),
    do: lift_expr(validate_scalar_integer_literal!(-integer), ctx, block, env)

  defp lift_expr({:+, _, [integer]}, ctx, block, env) when is_integer(integer),
    do: lift_expr(validate_scalar_integer_literal!(integer), ctx, block, env)

  # Preserve the established source spelling used to construct the minimum
  # term integer without first materializing the positive out-of-domain value.
  defp lift_expr({:-, _, [0, integer]}, ctx, block, env) when is_integer(integer),
    do: lift_expr(validate_scalar_integer_literal!(-integer), ctx, block, env)

  # An atom literal in value position lifts to its tagged word: a
  # deterministic hash payload (above the runtime's nil (0) and process pid
  # (1..8) ids), so equality (`==`, message matching) is sound per
  # compilation. `nil` is the runtime nil word.
  defp lift_expr(atom, ctx, block, env) when is_atom(atom) do
    word = atom_word(atom)

    {
      create_op(
        "ex.to_word",
        [lit(word, ctx, block)],
        [ex_type("term", ctx)],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr({:+, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.add", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr({:-, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.sub", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr({:*, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.mul", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr(binary, ctx, block, env) when is_binary(binary) do
    {values, env} =
      binary
      |> :binary.bin_to_list()
      |> Enum.map_reduce(env, fn byte, env ->
        {value, env} = lift_expr(byte, ctx, block, env)
        {box_term(value, ctx, block), env}
      end)

    {create_term_op("ex.binary", values, ctx, block), env}
  end

  defp lift_expr([], ctx, block, env) do
    {create_term_op("ex.list", [], ctx, block), env}
  end

  defp lift_expr([{:|, _, [head, tail]}], ctx, block, env) do
    {head, env} = lift_expr(head, ctx, block, env)
    {tail, env} = lift_expr(tail, ctx, block, env)

    value =
      create_op(
        "ex.list_cons",
        [
          create_op(
            "ex.to_word",
            [lift_value(head, ctx, block, env)],
            [ex_type("term", ctx)],
            ctx,
            block
          ),
          create_op(
            "ex.to_word",
            [lift_value(tail, ctx, block, env)],
            [ex_type("term", ctx)],
            ctx,
            block
          )
        ],
        [ex_type("term", ctx)],
        ctx,
        block
      )

    {value, env}
  end

  defp lift_expr(elements, ctx, block, env) when is_list(elements) do
    {values, env} = lift_operands_boxed(elements, ctx, block, env)
    {create_term_op("ex.list", values, ctx, block), env}
  end

  defp lift_expr({:%{}, _, [{:|, _, [base_ast, updates]}]}, ctx, block, env)
       when is_list(updates) do
    unless Enum.all?(updates, &match?({key, _value} when is_atom(key), &1)) do
      raise Error, "map updates only support literal atom keys: #{inspect(updates)}"
    end

    {base, env} = lift_expr(base_ast, ctx, block, env)
    base = box_term(lift_value(base, ctx, block, env), ctx, block)

    {updates, env} =
      Enum.map_reduce(updates, env, fn {key, value_ast}, env ->
        {value, env} = lift_expr(value_ast, ctx, block, env)
        {{key, box_term(lift_value(value, ctx, block, env), ctx, block)}, env}
      end)

    {lower_exact_map_update(base, updates, ctx, block), env}
  end

  defp lift_expr({:%{}, _, entries}, ctx, block, env) do
    {values, env} = lift_map_entries(entries, ctx, block, env)
    {create_term_op("ex.map", values, ctx, block), env}
  end

  defp lift_expr(
         {:%, _, [{:__aliases__, _, module_parts}, {:%{}, _, provided_fields}]},
         ctx,
         block,
         env
       ) do
    module = Elixir.Module.concat(module_parts)
    schemas = Map.get(env, @struct_schema_key)

    schema =
      case resolve_struct_schema(module, schemas) do
        {:ok, schema} ->
          schema

        :error ->
          raise Error,
                "struct constructor requires the current-module schema or registered schema, got: #{inspect(module)}"
      end

    entries = struct_constructor_entries(schema, provided_fields)
    {values, env} = lift_map_entries(entries, ctx, block, env)
    {create_term_op("ex.map", values, ctx, block), env}
  end

  defp lift_expr({:<<>>, _, segments}, ctx, block, env) do
    if Enum.any?(segments, &interpolation_segment?/1) do
      {values, env} = lift_interpolation_segments(segments, ctx, block, env)
      iodata = create_term_op("ex.list", values, ctx, block)
      {create_op("ex.iodata_to_binary", [iodata], [ex_type("term", ctx)], ctx, block), env}
    else
      {values, env} = lift_operands_boxed(segments, ctx, block, env)
      {create_term_op("ex.binary", values, ctx, block), env}
    end
  end

  defp lift_expr({:<>, _, [left_ast, right_ast]}, ctx, block, env) do
    {left, env} = lift_expr(left_ast, ctx, block, env)
    {right, env} = lift_expr(right_ast, ctx, block, env)
    left = box_term(lift_value(left, ctx, block, env), ctx, block)
    right = box_term(lift_value(right, ctx, block, env), ctx, block)

    left_binary = create_op("ex.is_binary", [left], [MLIR.Type.i64()], ctx, block)
    right_binary = create_op("ex.is_binary", [right], [MLIR.Type.i64()], ctx, block)

    both_binary =
      create_op("arith.andi", [left_binary, right_binary], [MLIR.Type.i64()], ctx, block)

    {lower_binary_concat(left, right, both_binary, ctx, block), env}
  end

  defp lift_expr({:&&, _, [left_ast, right_ast]}, ctx, block, env) do
    if ast_has_assignment?(right_ast) do
      raise Error, "assignments in the right-hand side of && are unsupported"
    end

    {left, env} = lift_expr(left_ast, ctx, block, env)
    left = box_term(lift_value(left, ctx, block, env), ctx, block)
    falsy = term_falsy_condition(left, ctx, block)

    {lower_short_circuit_and(left, right_ast, falsy, env, ctx, block), env}
  end

  defp lift_expr({:if, _, [condition_ast, options]}, ctx, block, env)
       when is_list(options) do
    then_ast = Keyword.fetch!(options, :do)
    else_ast = Keyword.get(options, :else, nil)

    if ast_has_assignment?(then_ast) or ast_has_assignment?(else_ast) do
      raise Error, "assignments in if branches are unsupported"
    end

    {condition, env} = lift_expr(condition_ast, ctx, block, env)
    condition = lift_value(condition, ctx, block, env)
    {condition, falsy} = lower_if_truthiness(condition_ast, condition, ctx, block)

    {lower_body_if(condition, then_ast, else_ast, falsy, env, ctx, block), env}
  end

  defp lift_expr({name, _, [arg]}, ctx, block, env)
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer, :is_float] do
    {value, env} = lift_expr(arg, ctx, block, env)
    {create_op("ex.#{name}", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block), env}
  end

  defp lift_expr({op, _, [left, right]}, ctx, block, env)
       when op in [:==, :!=, :===, :!==, :<, :<=, :>, :>=] do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    if term_operand?(left_value) or term_operand?(right_value) do
      unless op in [:==, :!=, :===, :!==] do
        raise Error, "ordering comparisons on terms are unsupported: #{inspect(op)}"
      end

      eq =
        create_op(
          "ex.term_eq",
          [box_if_scalar(left_value, ctx, block), box_if_scalar(right_value, ctx, block)],
          [MLIR.Type.i64()],
          ctx,
          block
        )

      if op in [:==, :===] do
        {eq, env}
      else
        {create_op(
           "ex.cmp",
           [eq, lit(0, ctx, block), predicate: MLIR.Attribute.string("eq")],
           [MLIR.Type.i64()],
           ctx,
           block
         ), env}
      end
    else
      {
        create_op(
          "ex.cmp",
          [left_value, right_value, predicate: MLIR.Attribute.string(cmp_predicate(op))],
          [MLIR.Type.i64()],
          ctx,
          block
        ),
        env
      }
    end
  end

  defp lift_expr({name, _, [left, right]}, ctx, block, env) when name in [:div, :rem] do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)
    ensure_refined_integer_operands!([left_value, right_value])
    op = if name == :div, do: "ex.div", else: "ex.rem"
    {create_op(op, [left_value, right_value], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_expr({:case, _, [scrutinee_ast, [do: clauses]]}, ctx, block, env) do
    {scrutinee, env} = lift_expr(scrutinee_ast, ctx, block, env)
    {lift_case(clauses, scrutinee, env, ctx, block), env}
  end

  defp lift_expr({:__batata_raise__, kind, reason_ast}, ctx, block, env) do
    {reason, env} = lift_expr(reason_ast, ctx, block, env)
    reason = box_term(reason, ctx, block)

    {create_op("ex.raise", [reason, lit(kind, ctx, block)], [ex_type("term", ctx)], ctx, block),
     env}
  end

  defp lift_expr({:__batata_raise_scalar__, kind, reason_ast}, ctx, block, env) do
    {raised, env} = lift_expr({:__batata_raise__, kind, reason_ast}, ctx, block, env)
    {create_op("ex.to_int", [raised], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_expr({:__block__, _, expressions}, ctx, block, env) do
    lift_block(expressions, ctx, block, env)
  end

  defp lift_expr({:=, _, [{var, _, nil}, rhs]}, ctx, block, env) when is_atom(var) do
    {value, env} = lift_expr(rhs, ctx, block, env)
    {value, Map.put(env, var, value)}
  end

  defp lift_expr({:=, _, [pattern, rhs]}, ctx, block, env) do
    {value, env} = lift_expr(rhs, ctx, block, env)
    value = box_if_scalar(lift_value(value, ctx, block, env), ctx, block)

    {_match_cond, binds} =
      build_match(pattern, value, ctx, block, false, Map.get(env, @struct_schema_key))

    {value, Enum.reduce(binds, env, fn {name, bound}, acc -> Map.put(acc, name, bound) end)}
  end

  # Anonymous-function marker produced by `extract_all_fns/1`: the literal
  # becomes a compile-time function reference. It is materialized into a
  # first-class closure word only when it crosses into a value context; a
  # direct `.()` application calls the extracted ex.func directly.
  defp lift_expr({:__fn_ref__, _, [fn_idx, name, arity, captured]}, _ctx, _block, env) do
    {{:fn_ref, fn_idx, name, arity, captured}, env}
  end

  # `Enum.map/2` / `Enum.reduce/3` calls recognized by `recognize_enum_calls`.
  defp lift_expr({:__enum_call__, _, [:map, pattern, enumerable_ast]}, ctx, block, env) do
    {enumerable, env} = lift_expr(enumerable_ast, ctx, block, env)
    enumerable_word = box_term(lift_value(enumerable, ctx, block, env), ctx, block)

    {value, env} =
      case pattern do
        :identity ->
          {enumerable_word, env}

        {:const, value} ->
          {lift_enum_const_map(
             enumerable_word,
             value,
             ctx,
             block,
             env[:__budget__],
             env[:__batch_size__]
           ), env}

        {:add_capture, capture_ast} ->
          {capture, env} = lift_expr(capture_ast, ctx, block, env)
          capture_i64 = enum_capture_i64(capture, ctx, block)

          {lift_enum_capture_map(
             enumerable_word,
             capture_i64,
             ctx,
             block,
             env[:__budget__],
             env[:__batch_size__]
           ), env}

        {:mapper, mapper_name} ->
          addr =
            create_op(
              "ex.func_addr",
              [sym_name: MLIR.Attribute.string(Symbol.function(mapper_name, 1))],
              [MLIR.Type.function([integer_type(ctx)], [integer_type(ctx)])],
              ctx,
              block
            )

          {
            create_op(
              "ex.enumerable_map_fun",
              [enumerable_word, addr],
              [ex_type("term", ctx)],
              ctx,
              block
            ),
            env
          }
      end

    mark_yield_gate(
      env[:__budget__],
      cursor_loop_map?(pattern),
      value,
      ctx,
      block,
      env
    )
  end

  defp lift_expr(
         {:__enum_call__, _, [:reduce, pattern, enumerable_ast, acc_ast]},
         ctx,
         block,
         env
       ) do
    {acc, env} = lift_expr(acc_ast, ctx, block, env)
    acc_value = lift_value(acc, ctx, block, env)

    case range_ast?(enumerable_ast) do
      {true, start_ast, stop_ast} ->
        case range_continuation(pattern) do
          nil ->
            raise Error, "range enumerables support only scalar reducers"

          cont ->
            {start, env} = lift_expr(start_ast, ctx, block, env)
            {stop, env} = lift_expr(stop_ast, ctx, block, env)
            {lift_enum_range_reduce(start, stop, acc_value, cont, ctx, block), env}
        end

      false ->
        {enumerable, env} = lift_expr(enumerable_ast, ctx, block, env)
        enumerable_word = box_term(lift_value(enumerable, ctx, block, env), ctx, block)

        {value, env} =
          lift_reduce_pattern(
            pattern,
            enumerable_ast,
            enumerable_word,
            acc_value,
            ctx,
            block,
            env
          )

        mark_yield_gate(
          env[:__budget__],
          cursor_loop_reduce?(pattern, enumerable_ast),
          value,
          ctx,
          block,
          env
        )
    end
  end

  defp lift_expr(
         {:__enum_call__, _, [:stream_filter, predicate_name, enumerable_ast]},
         ctx,
         block,
         env
       ) do
    {enumerable, env} = lift_expr(enumerable_ast, ctx, block, env)
    enumerable_word = box_term(lift_value(enumerable, ctx, block, env), ctx, block)

    addr =
      create_op(
        "ex.func_addr",
        [sym_name: MLIR.Attribute.string(Symbol.function(predicate_name, 1))],
        [MLIR.Type.function([integer_type(ctx)], [integer_type(ctx)])],
        ctx,
        block
      )

    {
      create_op(
        "ex.stream_filter",
        [enumerable_word, addr],
        [ex_type("term", ctx)],
        ctx,
        block
      ),
      env
    }
  end

  # Anonymous-function application: `f.(args)` / `(fn ... end).(args)`.
  defp lift_expr({{:., _, [fun_ast]}, _, args}, ctx, block, env) do
    case resolve_fun_ref(fun_ast, env) do
      {:ok, _fn_idx, name, arity, captured} ->
        unless length(args) == arity do
          raise Error,
                "anonymous function application arity mismatch: expected #{arity}, got #{length(args)}"
        end

        {arg_values, env} =
          Enum.map_reduce(args, env, fn arg, env ->
            lift_expr(arg, ctx, block, env)
          end)

        captured_values = resolve_captured(captured, env)
        captured_values = Enum.map(captured_values, &lift_value(&1, ctx, block, env))
        arg_values = Enum.map(arg_values, &lift_value(&1, ctx, block, env))

        # The extracted fn uses the fixed 8-slot closure ABI: four captured
        # slots followed by four argument slots.
        call_args =
          captured_values ++
            List.duplicate(zero_i64(ctx, block), 4 - length(captured_values)) ++
            arg_values ++ List.duplicate(zero_i64(ctx, block), 4 - length(arg_values))

        {
          create_op(
            "ex.call",
            call_args ++
              [
                callee: MLIR.Attribute.string(Symbol.function(name, 8)),
                arity: MLIR.Attribute.integer(MLIR.Type.i64(), 8),
                operandSegmentSizes: segment_sizes(arg_segment_sizes(8))
              ],
            [ex_type("term", ctx)],
            ctx,
            block
          ),
          env
        }

      {:dynamic, closure} ->
        unless length(args) <= 4 do
          raise Error,
                "dynamic anonymous function application supports at most 4 arguments, got #{length(args)}"
        end

        {arg_values, env} =
          Enum.map_reduce(args, env, fn arg, env ->
            lift_expr(arg, ctx, block, env)
          end)

        closure_word = create_op("ex.to_word", [closure], [ex_type("term", ctx)], ctx, block)

        {
          create_op(
            "ex.apply",
            [closure_word] ++
              arg_values ++
              [
                arg_count: MLIR.Attribute.integer(MLIR.Type.i64(), length(args)),
                operandSegmentSizes:
                  segment_sizes(
                    [1 | List.duplicate(1, length(args))] ++
                      List.duplicate(0, 4 - length(args))
                  )
              ],
            [ex_type("term", ctx)],
            ctx,
            block
          ),
          env
        }

      :error ->
        raise Error,
              "anonymous function application requires a fn literal or a bound function: " <>
                inspect(fun_ast)
    end
  end

  # Remote stdlib call: `Kernel.length(x)` / `List.first(x)` / `Enum.count(x)`.
  # Module-qualified calls resolve through the stdlib domain registry; anything
  # outside the declared surface raises explicitly.
  defp lift_expr({{:., _, [mod_ast, fun]}, _, args}, ctx, block, env)
       when is_atom(fun) and is_list(args) do
    case module_ref(mod_ast) do
      {:ok, module} ->
        lift_stdlib_call(module, fun, args, ctx, block, env)

      :error ->
        raise Error, "unsupported AST in the current slice: #{inspect(mod_ast)}.#{fun}"
    end
  end

  defp lift_expr({:self, _, []}, ctx, block, env) do
    {create_op("ex.self", [], [ex_type("term", ctx)], ctx, block), env}
  end

  defp lift_expr({:send, _, [pid_ast, msg_ast]}, ctx, block, env) do
    {pid_value, env} = lift_expr(pid_ast, ctx, block, env)
    {msg_value, env} = lift_expr(msg_ast, ctx, block, env)

    # A pid is always a term word (e.g. `self()` or a captured pid crossing a
    # closure boundary, where the captured slot is i64-typed). `ex.to_word` is
    # a pure passthrough, so an already-tagged word is never re-tagged.
    pid_word =
      create_op(
        "ex.to_word",
        [lift_value(pid_value, ctx, block, env)],
        [ex_type("term", ctx)],
        ctx,
        block
      )

    msg_word = box_term(lift_value(msg_value, ctx, block, env), ctx, block)

    {
      create_op("ex.send", [pid_word, msg_word], [ex_type("term", ctx)], ctx, block),
      env
    }
  end

  # `receive do pattern -> body end`: with a final catch-all clause the
  # message is popped FIFO and matched with a term case (empty or
  # non-matching messages fall through to the catch-all). Without a catch-all
  # the receive is selective (#35 slice 6): a preemptible mailbox scan skips
  # non-matching messages, and a message arrival invalidates the scan
  # continuation so it restarts and observes the new message.
  #
  # `after timeout_ms -> body end` (#35 slice 7): when no message matches, the
  # receive becomes a preemptible wait loop that yields to other processes and
  # re-scans until a match arrives or the timeout elapses (wall-clock
  # milliseconds via `ex.term.monotonic_time`; `:infinity` waits forever).
  defp lift_expr({:receive, _, [options]}, ctx, block, env) do
    clauses = Keyword.fetch!(options, :do)
    after_clause = parse_receive_after(Keyword.get(options, :after))

    if catch_all_clause?(List.last(clauses)) do
      if after_clause == nil do
        clauses = ensure_receive_catch_all(clauses)
        msg = create_op("ex.receive", [], [ex_type("term", ctx)], ctx, block)
        {lift_term_case(clauses, msg, env, ctx, block, untag_int_binds: true), env}
      else
        lift_receive_after_fifo(clauses, after_clause, ctx, block, env)
      end
    else
      lift_selective_receive(clauses, ctx, block, env, after_clause)
    end
  end

  defp lift_expr({:throw, _, [value_ast]}, ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = box_term(lift_value(value, ctx, block, env), ctx, block)
    {create_op("ex.throw", [value], [ex_type("term", ctx)], ctx, block), env}
  end

  # `try do body catch pattern -> handler end`: the body region runs normally;
  # a `throw` longjmps back and the catch region matches the thrown value.
  defp lift_expr({:try, _, [options]}, ctx, block, env) do
    if Enum.any?([:rescue, :after, :else], &Keyword.has_key?(options, &1)) do
      raise Error, "only try/catch is supported in the current slice"
    end

    body = Keyword.fetch!(options, :do)
    catch_clauses = Keyword.fetch!(options, :catch) |> ensure_receive_catch_all()

    body_region = MLIR.CAPI.mlirRegionCreate()
    body_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(body_region, body_block)

    {body_value, body_env} = lift_block(List.wrap(body), ctx, body_block, env)
    body_value = lift_value(body_value, ctx, body_block, body_env)

    create_op(
      "ex.yield",
      [body_value, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      body_block
    )

    catch_region = MLIR.CAPI.mlirRegionCreate()
    catch_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(catch_region, catch_block)

    thrown = create_op("ex.catch_value", [], [ex_type("term", ctx)], ctx, catch_block)

    catch_value =
      lift_term_case(catch_clauses, thrown, env, ctx, catch_block, untag_int_binds: true)

    create_op(
      "ex.yield",
      [catch_value, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      catch_block
    )

    try_op =
      %Beaver.SSA{
        op: "ex.try",
        ip: block,
        ctx: ctx,
        results: [ex_type("term", ctx)],
        loc: MLIR.Location.unknown(),
        filler: fn -> [body_region, catch_region] end
      }
      |> MLIR.Operation.create()

    {try_op |> MLIR.Operation.results() |> Enum.to_list() |> hd(), env}
  end

  # Tuple literal AST: `{a, b, c}` parses to `{:{}, meta, [a, b, c]}` for
  # arity >= 3 (two-element tuples are already 2-tuples in quoted form).
  defp lift_expr({:{}, _, elements}, ctx, block, env) when is_list(elements) do
    lift_tuple_literal(List.to_tuple(elements), ctx, block, env)
  end

  defp lift_expr({name, _, args}, ctx, block, env) when is_atom(name) and is_list(args) do
    if Batata.Stdlib.class({Kernel, name, length(args)}) == :native_term do
      # Kernel auto-imported BIFs (length/1, hd/1, ...) resolve through the
      # stdlib registry; user definitions of the same name are not visible in
      # this slice, matching the existing self/0 and send/2 special cases.
      lift_stdlib_call(Kernel, name, args, ctx, block, env)
    else
      {arg_values, env} =
        Enum.map_reduce(args, env, fn arg, env ->
          {value, env} = lift_expr(arg, ctx, block, env)
          {lift_value(value, ctx, block, env), env}
        end)

      arg_values = adapt_call_arguments(name, arg_values, env, ctx, block)

      {
        create_op(
          "ex.call",
          arg_values ++
            [
              callee: MLIR.Attribute.string(Symbol.function(name, length(args))),
              arity: MLIR.Attribute.integer(MLIR.Type.i64(), length(args)),
              operandSegmentSizes: segment_sizes(arg_segment_sizes(length(args)))
            ],
          [ex_type("term", ctx)],
          ctx,
          block
        ),
        env
      }
    end
  end

  defp lift_expr({name, _, nil}, _ctx, _block, env) when is_atom(name) do
    case Map.fetch(env, name) do
      {:ok, value} -> {value, env}
      :error -> raise Error, "unbound variable reference: #{inspect(name)}"
    end
  end

  # Tuple literals: calls, operators and variables are 3-tuples in the AST and
  # are handled above, so every other tuple shape is a literal tuple.
  defp lift_expr(tuple, ctx, block, env) when is_tuple(tuple) and tuple_size(tuple) != 3 do
    lift_tuple_literal(tuple, ctx, block, env)
  end

  defp lift_expr({a, b, c}, ctx, block, env)
       when not (is_atom(a) and is_list(b) and is_list(c)) do
    lift_tuple_literal({a, b, c}, ctx, block, env)
  end

  defp lift_expr(ast, _ctx, _block, _env) do
    raise Error, "unsupported AST in the current slice: #{inspect(ast)}"
  end

  defp validate_term_integer_literal!(integer)
       when integer >= @min_term_integer and integer <= @max_term_integer,
       do: integer

  defp validate_term_integer_literal!(integer) do
    raise Error,
          "integer literal #{integer} is outside the signed 61-bit term domain " <>
            "(#{@min_term_integer}..#{@max_term_integer})"
  end

  defp validate_scalar_integer_literal!(integer)
       when integer >= @min_scalar_integer and integer <= @max_scalar_integer,
       do: integer

  defp validate_scalar_integer_literal!(integer) do
    raise Error,
          "integer literal #{integer} is outside the signed 64-bit scalar domain " <>
            "(#{@min_scalar_integer}..#{@max_scalar_integer})"
  end

  defp interpolation_segment?({:"::", _, [_, {:binary, _, nil}]}), do: true
  defp interpolation_segment?(_segment), do: false

  defp ast_has_assignment?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        {:=, _, _} = node, false -> {node, true}
        node, false -> {node, false}
      end)

    found?
  end

  defp lift_interpolation_segments(segments, ctx, block, env) do
    Enum.map_reduce(segments, env, fn
      {:"::", _, [expression, {:binary, _, nil}]}, env ->
        {value, env} = lift_expr(expression, ctx, block, env)
        {box_term(value, ctx, block), env}

      segment, env ->
        {value, env} = lift_expr(segment, ctx, block, env)
        {box_term(value, ctx, block), env}
    end)
  end

  # Selective receive: a cursor loop over the mailbox that tries each message
  # against the clauses and removes the first match. The loop state is
  # (found, result, cursor); with a reduction budget the scan is preemptible
  # and saves a receive-type continuation, which a message arrival
  # invalidates — the scan then restarts and observes the new message.
  defp blocking_receive?(nil), do: true
  defp blocking_receive?({:infinity, _body}), do: true
  defp blocking_receive?(_after_clause), do: false

  defp lift_selective_receive(clauses, ctx, block, env, after_clause) do
    i64 = integer_type(ctx)
    i1 = MLIR.Type.i1()
    budget = env[:__budget__]
    parsed = Enum.map(clauses, &parse_term_clause/1)
    blocking? = blocking_receive?(after_clause)

    {state_found, state_result, state_cursor, state_countdown, arity} =
      if budget == nil do
        {s_f, s_r, s_c} =
          resumable_loop_state(block, ctx, budget, fn b ->
            {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
          end)

        {s_f, s_r, s_c, nil, 3}
      else
        {s_f, s_r, s_c, s_cd} =
          resumable_loop_state(
            block,
            ctx,
            budget,
            fn b ->
              {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
            end,
            env[:__batch_size__]
          )

        {s_f, s_r, s_c, s_cd, 4}
      end

    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), arity)
    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_found, b_result, b_cursor | b_rest] = before_block |> Walker.arguments() |> Enum.to_list()
    len = create_op("ex.mailbox_len", [], [i64], ctx, before_block)

    not_found_i1 =
      create_op(
        "arith.trunci",
        [cmp(b_found, 0, "eq", ctx, before_block)],
        [i1],
        ctx,
        before_block
      )

    more_i1 =
      create_op(
        "arith.trunci",
        [cmp(b_cursor, len, "slt", ctx, before_block)],
        [i1],
        ctx,
        before_block
      )

    cond_i1 =
      if blocking? do
        create_op("arith.andi", [not_found_i1, more_i1], [i1], ctx, before_block)
      else
        # With `after`, a completed scan round (cursor >= len) is handled in
        # the body: the wait loop re-scans or times out.
        not_found_i1
      end

    {budget_cond, next_countdown} =
      inject_reduction_tick(
        before_block,
        ctx,
        cond_i1,
        budget,
        {b_found, b_result, b_cursor, List.first(b_rest) || lit(0, ctx, before_block)},
        true,
        env[:__batch_size__]
      )

    create_op(
      "scf.condition",
      [budget_cond, b_found, b_result, b_cursor] ++
        if(next_countdown == nil, do: [], else: [next_countdown]),
      [],
      ctx,
      before_block
    )

    [a_found, a_result, a_cursor | a_rest] = after_block |> Walker.arguments() |> Enum.to_list()
    len = create_op("ex.mailbox_len", [], [i64], ctx, after_block)

    more_i1 =
      create_op(
        "arith.trunci",
        [cmp(a_cursor, len, "slt", ctx, after_block)],
        [i1],
        ctx,
        after_block
      )

    {n_found, n_result, n_cursor} =
      if blocking? do
        msg = create_op("ex.mailbox_peek", [a_cursor], [ex_type("term", ctx)], ctx, after_block)
        receive_match_try(parsed, msg, a_cursor, env, ctx, after_block, i64)
      else
        [f, r, c] =
          build_scf_if(
            more_i1,
            ctx,
            after_block,
            [i64, i64, i64],
            fn b ->
              msg = create_op("ex.mailbox_peek", [a_cursor], [ex_type("term", ctx)], ctx, b)
              {f, r, c} = receive_match_try(parsed, msg, a_cursor, env, ctx, b, i64)
              [f, r, c]
            end,
            fn b ->
              {f, r, c} =
                receive_timeout_check(after_clause, a_found, a_result, a_cursor, env, ctx, b)

              [f, r, c]
            end
          )

        {f, r, c}
      end

    create_op(
      "scf.yield",
      [n_found, n_result, n_cursor] ++
        if(next_countdown == nil, do: [], else: [List.first(a_rest)]),
      [],
      ctx,
      after_block
    )

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments:
          [state_found, state_result, state_cursor] ++
            if(next_countdown == nil, do: [], else: [state_countdown]),
        results: List.duplicate(i64, arity),
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    [found, result, cursor | _rest] = while_op |> MLIR.Operation.results() |> Enum.to_list()
    found_i1 = create_op("arith.trunci", [cmp(found, 0, "ne", ctx, block)], [i1], ctx, block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("term", ctx)], ctx, block)
    nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, block)

    final =
      build_scf_if(
        found_i1,
        ctx,
        block,
        [i64],
        fn _b -> [result] end,
        fn b ->
          if blocking? do
            create_op("ex.receive_cont_save", [found, result, cursor], [i64], ctx, b)
            create_op("ex.process_wait", [cursor], [i64], ctx, b)
          end

          [nil_i64]
        end
      )
      |> hd()

    {final, env}
  end

  # Tries the remaining clauses against the peeked message: the first match
  # removes the message and yields (found=1, body value, cursor); no match
  # advances the cursor. Nested `scf.if`s select the first matching clause.
  defp receive_match_try([], _msg, cursor, _env, ctx, block, i64) do
    next_cursor = create_op("ex.add", [cursor, lit(1, ctx, block)], [i64], ctx, block)
    {lit(0, ctx, block), lit(0, ctx, block), next_cursor}
  end

  defp receive_match_try([clause | rest], msg, cursor, env, ctx, block, i64) do
    %{pattern: pattern, guard: guard, body: body} = clause

    {match_cond, binds} =
      build_match(pattern, msg, ctx, block, guard == nil, Map.get(env, @struct_schema_key))

    cond =
      case guard do
        nil ->
          match_cond

        guard_ast ->
          guard_cond = lift_term_guard(guard_ast, binds, env, ctx, block)
          combine([match_cond, guard_cond], ctx, block)
      end

    binds =
      case integer_guard_var(guard) do
        nil ->
          binds

        var ->
          Enum.map(binds, fn
            {^var, value} ->
              {var, create_op("ex.to_int", [value], [MLIR.Type.i64()], ctx, block)}

            other ->
              other
          end)
      end

    cond_i1 =
      create_op(
        "arith.trunci",
        [cond || lit(1, ctx, block)],
        [MLIR.Type.i1()],
        ctx,
        block
      )

    [n_found, n_result, n_cursor] =
      build_scf_if(
        cond_i1,
        ctx,
        block,
        [i64, i64, i64],
        fn b ->
          clause_env =
            Enum.reduce(binds, env, fn
              {var, {:deferred, fun}}, acc -> Map.put(acc, var, fun.(b))
              {var, value}, acc -> Map.put(acc, var, value)
            end)

          {value, clause_env} = lift_block(List.wrap(body), ctx, b, clause_env)
          value = lift_value(value, ctx, b, clause_env)
          # The scan loop state is scalar; a body that returns a raw term word
          # (e.g. a nested receive's message) is carried as its word value.
          value = if term_operand?(value), do: unbox(value, ctx, b), else: value
          create_op("ex.mailbox_remove", [cursor], [i64], ctx, b)
          [lit(1, ctx, b), value, cursor]
        end,
        fn b ->
          {f, r, c} = receive_match_try(rest, msg, cursor, env, ctx, b, i64)
          [f, r, c]
        end
      )

    {n_found, n_result, n_cursor}
  end

  # `receive ... after` wait-loop step for a completed scan round (or an empty
  # FIFO pop): restarts the round until the timeout elapses, then yields the
  # after body. The timeout start lives in the process's `receive_start` slot
  # (0 = timing not started yet); `:infinity` never times out.
  defp receive_timeout_check({:infinity, _body}, _found, _result, cursor, _env, ctx, block) do
    {lit(0, ctx, block), lit(0, ctx, block), cursor}
  end

  defp receive_timeout_check({:timeout, 0, body}, _found, _result, cursor, env, ctx, block) do
    {lit(1, ctx, block), lift_after_body(body, env, ctx, block), cursor}
  end

  defp receive_timeout_check(
         {:timeout, timeout_ms, body},
         _found,
         _result,
         cursor,
         env,
         ctx,
         block
       ) do
    i64 = integer_type(ctx)
    i1 = MLIR.Type.i1()
    now = create_op("ex.monotonic_time", [], [i64], ctx, block)
    start = create_op("ex.receive_start", [], [i64], ctx, block)

    is_first_i1 =
      create_op("arith.trunci", [cmp(start, 0, "eq", ctx, block)], [i1], ctx, block)

    [f, r, c] =
      build_scf_if(
        is_first_i1,
        ctx,
        block,
        [i64, i64, i64],
        fn b ->
          create_op("ex.receive_start_set", [now], [i64], ctx, b)
          [lit(0, ctx, b), lit(0, ctx, b), cursor]
        end,
        fn b ->
          elapsed = create_op("ex.sub", [now, start], [i64], ctx, b)

          timed_out_i1 =
            create_op(
              "arith.trunci",
              [cmp(elapsed, timeout_ms, "sge", ctx, b)],
              [i1],
              ctx,
              b
            )

          build_scf_if(
            timed_out_i1,
            ctx,
            b,
            [i64, i64, i64],
            fn tb ->
              [lit(1, ctx, tb), lift_after_body(body, env, ctx, tb), cursor]
            end,
            fn tb ->
              [lit(0, ctx, tb), lit(0, ctx, tb), cursor]
            end
          )
        end
      )

    {f, r, c}
  end

  defp lift_after_body(body, env, ctx, block) do
    {value, _env} = lift_block(List.wrap(body), ctx, block, env)
    lift_value(value, ctx, block, env)
  end

  # FIFO `receive` with `after`: a pop that finds the mailbox empty enters the
  # wait loop (re-pop until a message arrives or the timeout elapses);
  # non-empty pops match through the catch-all as usual.
  defp lift_receive_after_fifo(clauses, after_clause, ctx, block, env) do
    i64 = integer_type(ctx)
    i1 = MLIR.Type.i1()
    budget = env[:__budget__]
    clauses = ensure_receive_catch_all(clauses)

    {state_found, state_result, state_cursor, state_countdown, arity} =
      if budget == nil do
        {s_f, s_r, s_c} =
          resumable_loop_state(block, ctx, budget, fn b ->
            {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
          end)

        {s_f, s_r, s_c, nil, 3}
      else
        {s_f, s_r, s_c, s_cd} =
          resumable_loop_state(
            block,
            ctx,
            budget,
            fn b ->
              {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
            end,
            env[:__batch_size__]
          )

        {s_f, s_r, s_c, s_cd, 4}
      end

    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), arity)
    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_found, b_result, b_cursor | b_rest] = before_block |> Walker.arguments() |> Enum.to_list()

    not_found_i1 =
      create_op(
        "arith.trunci",
        [cmp(b_found, 0, "eq", ctx, before_block)],
        [i1],
        ctx,
        before_block
      )

    {budget_cond, next_countdown} =
      inject_reduction_tick(
        before_block,
        ctx,
        not_found_i1,
        budget,
        {b_found, b_result, b_cursor, List.first(b_rest) || lit(0, ctx, before_block)},
        true,
        env[:__batch_size__]
      )

    create_op(
      "scf.condition",
      [budget_cond, b_found, b_result, b_cursor] ++
        if(next_countdown == nil, do: [], else: [next_countdown]),
      [],
      ctx,
      before_block
    )

    [a_found, a_result, a_cursor | a_rest] = after_block |> Walker.arguments() |> Enum.to_list()
    msg = create_op("ex.receive", [], [ex_type("term", ctx)], ctx, after_block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("term", ctx)], ctx, after_block)
    is_empty = create_op("ex.term_eq", [msg, nil_dyn], [i64], ctx, after_block)
    is_empty_i1 = create_op("arith.trunci", [is_empty], [i1], ctx, after_block)

    [n_found, n_result, n_cursor] =
      build_scf_if(
        is_empty_i1,
        ctx,
        after_block,
        [i64, i64, i64],
        fn b ->
          {f, r, c} =
            receive_timeout_check(after_clause, a_found, a_result, a_cursor, env, ctx, b)

          [f, r, c]
        end,
        fn b ->
          value = lift_term_case(clauses, msg, env, ctx, b, untag_int_binds: true)
          [lit(1, ctx, b), value, a_cursor]
        end
      )

    create_op(
      "scf.yield",
      [n_found, n_result, n_cursor] ++
        if(next_countdown == nil, do: [], else: [List.first(a_rest)]),
      [],
      ctx,
      after_block
    )

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments:
          [state_found, state_result, state_cursor] ++
            if(next_countdown == nil, do: [], else: [state_countdown]),
        results: List.duplicate(i64, arity),
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    [found, result, _cursor | _rest] = while_op |> MLIR.Operation.results() |> Enum.to_list()
    found_i1 = create_op("arith.trunci", [cmp(found, 0, "ne", ctx, block)], [i1], ctx, block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("term", ctx)], ctx, block)
    nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, block)

    final =
      build_scf_if(found_i1, ctx, block, [i64], fn _b -> [result] end, fn _b -> [nil_i64] end)
      |> hd()

    {final, env}
  end

  # `after` value AST: `[timeout_ast, [do: body]]`; the timeout is an integer
  # literal (>= 0) or `:infinity`.
  defp parse_receive_after(nil), do: nil

  defp parse_receive_after([{:->, _, [[timeout_ast], body]}]) do
    case timeout_ast do
      :infinity ->
        {:infinity, body}

      timeout when is_integer(timeout) and timeout >= 0 ->
        {:timeout, timeout, body}

      _ ->
        raise Error,
              "receive after timeout must be an integer literal or :infinity, got: " <>
                inspect(timeout_ast)
    end
  end

  defp parse_receive_after(other) do
    raise Error, "malformed receive after clause: #{inspect(other)}"
  end

  # `erlang.unique_integer/1` modifiers: a literal list of
  # `:positive`/`:negative`/`:monotonic`; negative selects the decreasing
  # series (the single-threaded counter is naturally monotonic, so
  # `:monotonic` needs no extra handling).
  defp unique_integer_modifiers(modifiers) when is_list(modifiers) do
    if Enum.all?(modifiers, &(&1 in [:positive, :negative, :monotonic])) do
      {:ok, :negative in modifiers}
    else
      :error
    end
  end

  defp unique_integer_modifiers(_modifiers), do: :error

  defp atom_word(nil), do: 1
  defp atom_word(atom), do: (16 + :erlang.phash2(atom)) * 8 + 1

  defp atom_term(atom, ctx, block) do
    create_op(
      "ex.to_word",
      [lit(atom_word(atom), ctx, block)],
      [ex_type("term", ctx)],
      ctx,
      block
    )
  end

  defp boolean_term(value, ctx, block) do
    condition = create_op("arith.trunci", [value], [MLIR.Type.i1()], ctx, block)

    word =
      build_scf_if(
        condition,
        ctx,
        block,
        [integer_type(ctx)],
        fn b ->
          [lit(atom_word(true), ctx, b)]
        end,
        fn b ->
          [lit(atom_word(false), ctx, b)]
        end
      )
      |> hd()

    create_op("ex.to_word", [word], [ex_type("term", ctx)], ctx, block)
  end

  defp ensure_receive_catch_all(clauses) do
    if catch_all_clause?(List.last(clauses)) do
      clauses
    else
      clauses ++ [{:->, [], [[{:_, [], nil}], 0]}]
    end
  end

  defp lift_reduce_pattern(
         :sum,
         enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    if is_list(enumerable_ast) do
      # A list literal keeps the compile-time cursor loop (M3); other
      # enumerables (tuple/binary literals or variables) dispatch through
      # the runtime's tag-based enumerable reduce.
      {lift_enum_sum_loop(
         enumerable_word,
         acc_value,
         ctx,
         block,
         env[:__budget__],
         env[:__batch_size__]
       ), env}
    else
      {lift_enum_reduce_runtime(enumerable_word, acc_value, 1, ctx, block), env}
    end
  end

  defp lift_reduce_pattern(
         :product,
         enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    if is_list(enumerable_ast) do
      {lift_enum_product_loop(
         enumerable_word,
         acc_value,
         ctx,
         block,
         env[:__budget__],
         env[:__batch_size__]
       ), env}
    else
      {lift_enum_reduce_runtime(enumerable_word, acc_value, 6, ctx, block), env}
    end
  end

  defp lift_reduce_pattern(
         :subtract_acc_first,
         enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    lift_subtract_pattern(
      enumerable_ast,
      enumerable_word,
      acc_value,
      :acc_first,
      7,
      ctx,
      block,
      env
    )
  end

  defp lift_reduce_pattern(
         :subtract_item_first,
         enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    lift_subtract_pattern(
      enumerable_ast,
      enumerable_word,
      acc_value,
      :item_first,
      8,
      ctx,
      block,
      env
    )
  end

  defp lift_reduce_pattern(
         pattern,
         _enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       )
       when pattern in [
              :div_acc_first,
              :div_item_first,
              :rem_acc_first,
              :rem_item_first,
              :map_values_sum,
              :map_keys_sum,
              :map_entries_sum
            ] do
    continuation = reduce_continuation(pattern)
    {lift_enum_reduce_runtime(enumerable_word, acc_value, continuation, ctx, block), env}
  end

  defp lift_reduce_pattern(
         {:capture_sum, capture_ast},
         _enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    {capture, env} = lift_expr(capture_ast, ctx, block, env)
    capture_i64 = enum_capture_i64(capture, ctx, block)
    {lift_enum_reduce_capture(enumerable_word, acc_value, capture_i64, ctx, block), env}
  end

  defp lift_reduce_pattern(
         {:capture_product, capture_ast},
         _enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    {capture, env} = lift_expr(capture_ast, ctx, block, env)
    capture_i64 = enum_capture_i64(capture, ctx, block)
    {lift_enum_reduce_capture(enumerable_word, acc_value, capture_i64, ctx, block, 14), env}
  end

  defp lift_reduce_pattern(
         {:combination, reducer_name},
         _enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    # Any enumerable: the reducer was extracted to `__enum_reducer_N`,
    # whose address is handed to the runtime's arbitrary-closure reduce.
    addr =
      create_op(
        "ex.func_addr",
        [sym_name: MLIR.Attribute.string(Symbol.function(reducer_name, 2))],
        [MLIR.Type.function([integer_type(ctx), integer_type(ctx)], [integer_type(ctx)])],
        ctx,
        block
      )

    {
      create_op(
        "ex.enumerable_reduce_fun",
        [enumerable_word, acc_value, addr],
        [integer_type(ctx)],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_reduce_pattern(
         :return_acc,
         _enumerable_ast,
         _enumerable_word,
         acc_value,
         _ctx,
         _block,
         env
       ) do
    {acc_value, env}
  end

  defp lift_subtract_pattern(
         enumerable_ast,
         enumerable_word,
         acc_value,
         direction,
         continuation,
         ctx,
         block,
         env
       ) do
    if is_list(enumerable_ast) do
      {lift_enum_subtract_loop(
         enumerable_word,
         acc_value,
         direction,
         ctx,
         block,
         env[:__budget__],
         env[:__batch_size__]
       ), env}
    else
      {lift_enum_reduce_runtime(enumerable_word, acc_value, continuation, ctx, block), env}
    end
  end

  # Integer division/remainder and map projections reduce through runtime
  # continuations (the ex dialect has no div/rem operations).
  defp reduce_continuation(:map_values_sum), do: 3
  defp reduce_continuation(:map_keys_sum), do: 4
  defp reduce_continuation(:map_entries_sum), do: 5
  defp reduce_continuation(:div_acc_first), do: 9
  defp reduce_continuation(:div_item_first), do: 10
  defp reduce_continuation(:rem_acc_first), do: 11
  defp reduce_continuation(:rem_item_first), do: 12

  defp catch_all_clause?({:->, _, [[pattern], _body]}) do
    match?({name, _, nil} when is_atom(name), pattern)
  end

  defp catch_all_clause?(_clause), do: false

  defp module_ref({:__aliases__, _, [module]}) when is_atom(module),
    do: {:ok, Module.concat([module])}

  defp module_ref({:__aliases__, _, [:"Elixir", module]}) when is_atom(module),
    do: {:ok, Module.concat([:"Elixir", module])}

  # A bare lowercase atom module reference (`erlang.monotonic_time()` parses
  # the module as `{:erlang, meta, nil}`).
  defp module_ref({module, _, nil}) when is_atom(module), do: {:ok, module}

  defp module_ref(module) when is_atom(module), do: {:ok, module}
  defp module_ref(_), do: :error

  # Resolves a module-qualified stdlib call through the domain registry.
  # Dates are gregorian days (i64) in the slice: `Date.new(y, m, d)` with
  # integer literals is folded at lift time, so `a..b` over dates reuses the
  # integer range paths.
  defp lift_stdlib_call(Date, :new, [year, month, day], ctx, block, env) do
    if is_integer(year) and is_integer(month) and is_integer(day) do
      days = Calendar.ISO.date_to_iso_days(year, month, day)
      {lit(days, ctx, block), env}
    else
      raise Error, "Date.new requires integer literal arguments in this slice"
    end
  end

  defp lift_stdlib_call(Time, :new, [hour, minute, second], ctx, block, env) do
    lift_time_new(hour, minute, second, 0, 0, ctx, block, env)
  end

  defp lift_stdlib_call(
         Time,
         :new,
         [hour, minute, second, {microsecond, precision}],
         ctx,
         block,
         env
       ) do
    lift_time_new(hour, minute, second, microsecond, precision, ctx, block, env)
  end

  defp lift_stdlib_call(Time, :new, _args, _ctx, _block, _env) do
    raise Error, "Time.new requires valid integer literal arguments in this slice"
  end

  defp lift_stdlib_call(
         NaiveDateTime,
         :new,
         [year, month, day, hour, minute, second],
         ctx,
         block,
         env
       ) do
    lift_naive_datetime_new(
      [year, month, day, hour, minute, second],
      ctx,
      block,
      env
    )
  end

  defp lift_stdlib_call(
         NaiveDateTime,
         :new,
         [year, month, day, hour, minute, second, {microsecond, precision}],
         ctx,
         block,
         env
       ) do
    lift_naive_datetime_new(
      [year, month, day, hour, minute, second, microsecond, precision],
      ctx,
      block,
      env
    )
  end

  defp lift_stdlib_call(NaiveDateTime, :new, _args, _ctx, _block, _env) do
    raise Error,
          "NaiveDateTime.new requires valid integer literal arguments in this slice"
  end

  defp lift_stdlib_call(Date, :to_iso8601, [value_ast], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = lift_value(value, ctx, block, env)

    {days, integer?} =
      if term_operand?(value) do
        {create_op("ex.to_int", [value], [integer_type(ctx)], ctx, block),
         create_op("ex.is_integer", [value], [integer_type(ctx)], ctx, block)}
      else
        {value, lit(1, ctx, block)}
      end

    lower = cmp(days, -3_652_059, "sge", ctx, block)
    upper = cmp(days, 3_652_424, "sle", ctx, block)
    in_range = create_op("arith.andi", [lower, upper], [integer_type(ctx)], ctx, block)
    valid = create_op("arith.andi", [integer?, in_range], [integer_type(ctx)], ctx, block)
    valid_i1 = create_op("arith.trunci", [valid], [MLIR.Type.i1()], ctx, block)

    result_word =
      build_scf_if(
        valid_i1,
        ctx,
        block,
        [integer_type(ctx)],
        fn b -> [lower_date_to_iso8601(days, ctx, b) |> unbox(ctx, b)] end,
        fn b ->
          [raise_argument_error("invalid Date.to_iso8601/1 date", ctx, b) |> unbox(ctx, b)]
        end
      )
      |> hd()

    {create_op("ex.to_word", [result_word], [ex_type("term", ctx)], ctx, block), env}
  end

  defp lift_stdlib_call(Time, :to_iso8601, [value_ast], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = lift_value(value, ctx, block, env)

    {packed, integer?} =
      if term_operand?(value) do
        {create_op("ex.to_int", [value], [integer_type(ctx)], ctx, block),
         create_op("ex.is_integer", [value], [integer_type(ctx)], ctx, block)}
      else
        {value, lit(1, ctx, block)}
      end

    precision = date_rem(packed, 10, ctx, block)
    lower = cmp(packed, 0, "sge", ctx, block)
    upper = cmp(packed, 863_999_999_996, "sle", ctx, block)
    precision_valid = cmp(precision, 6, "sle", ctx, block)
    in_range = create_op("arith.andi", [lower, upper], [integer_type(ctx)], ctx, block)

    valid_shape =
      create_op("arith.andi", [in_range, precision_valid], [integer_type(ctx)], ctx, block)

    valid = create_op("arith.andi", [integer?, valid_shape], [integer_type(ctx)], ctx, block)
    valid_i1 = create_op("arith.trunci", [valid], [MLIR.Type.i1()], ctx, block)

    result_word =
      build_scf_if(
        valid_i1,
        ctx,
        block,
        [integer_type(ctx)],
        fn b -> [lower_time_to_iso8601(packed, ctx, b) |> unbox(ctx, b)] end,
        fn b ->
          [raise_argument_error("invalid Time.to_iso8601/1 time", ctx, b) |> unbox(ctx, b)]
        end
      )
      |> hd()

    {create_op("ex.to_word", [result_word], [ex_type("term", ctx)], ctx, block), env}
  end

  defp lift_stdlib_call(NaiveDateTime, :to_iso8601, [value_ast], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = lift_value(value, ctx, block, env)

    {packed, integer?} =
      if term_operand?(value) do
        {create_op("ex.to_int", [value], [integer_type(ctx)], ctx, block),
         create_op("ex.is_integer", [value], [integer_type(ctx)], ctx, block)}
      else
        {value, lit(1, ctx, block)}
      end

    precision = date_rem(packed, 10, ctx, block)
    lower = cmp(packed, 0, "sge", ctx, block)
    upper = cmp(packed, 6_311_074_175_999_999_996, "sle", ctx, block)
    precision_valid = cmp(precision, 6, "sle", ctx, block)
    in_range = create_op("arith.andi", [lower, upper], [integer_type(ctx)], ctx, block)

    valid_shape =
      create_op("arith.andi", [in_range, precision_valid], [integer_type(ctx)], ctx, block)

    valid = create_op("arith.andi", [integer?, valid_shape], [integer_type(ctx)], ctx, block)
    valid_i1 = create_op("arith.trunci", [valid], [MLIR.Type.i1()], ctx, block)

    result_word =
      build_scf_if(
        valid_i1,
        ctx,
        block,
        [integer_type(ctx)],
        fn b -> [lower_naive_datetime_to_iso8601(packed, ctx, b) |> unbox(ctx, b)] end,
        fn b ->
          [
            raise_argument_error("invalid NaiveDateTime.to_iso8601/1 datetime", ctx, b)
            |> unbox(ctx, b)
          ]
        end
      )
      |> hd()

    {create_op("ex.to_word", [result_word], [ex_type("term", ctx)], ctx, block), env}
  end

  # Logical-clock mapping (#35 slice 8): `erlang.monotonic_time/0,1` reads the
  # runtime's native clock (nanoseconds) and converts to the requested unit;
  # `erlang.unique_integer/0,1` hands out fresh increasing (or, for
  # `:negative`, decreasing) values from the runtime counter.
  defp lift_stdlib_call(:erlang, :monotonic_time, [], ctx, block, env) do
    {create_op("ex.native_time", [], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_stdlib_call(:erlang, :monotonic_time, [unit_ast], ctx, block, env) do
    divisor = monotonic_time_divisor(unit_ast)
    native = create_op("ex.native_time", [], [integer_type(ctx)], ctx, block)

    {
      create_op("ex.div", [native, lit(divisor, ctx, block)], [integer_type(ctx)], ctx, block),
      env
    }
  end

  defp lift_stdlib_call(:erlang, :unique_integer, [], ctx, block, env) do
    {create_op("ex.unique_integer", [lit(0, ctx, block)], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_stdlib_call(:erlang, :unique_integer, [modifiers_ast], ctx, block, env) do
    negative =
      case unique_integer_modifiers(modifiers_ast) do
        {:ok, negative?} -> negative?
        :error -> raise Error, "unsupported unique_integer modifiers: #{inspect(modifiers_ast)}"
      end

    flag = if negative, do: 1, else: 0

    {create_op("ex.unique_integer", [lit(flag, ctx, block)], [integer_type(ctx)], ctx, block),
     env}
  end

  defp lift_stdlib_call(module, function, [flag, enabled], ctx, block, env)
       when module in [Process, :erlang] and function in [:flag, :process_flag] do
    unless flag == :trap_exit and is_boolean(enabled) do
      raise Error, "only literal trap_exit boolean process flags are supported"
    end

    previous =
      create_op(
        "ex.process_trap_exit",
        [lit(if(enabled, do: 1, else: 0), ctx, block)],
        [integer_type(ctx)],
        ctx,
        block
      )

    {boolean_term(previous, ctx, block), env}
  end

  defp lift_stdlib_call(:erlang, :monitor, [type, pid_ast], ctx, block, env) do
    unless type == :process do
      raise Error, "only :process monitors are supported"
    end

    {pid, env} = lift_expr(pid_ast, ctx, block, env)
    {native_term_call(Process, :monitor, [box_term(pid, ctx, block)], ctx, block), env}
  end

  defp lift_stdlib_call(Kernel, :to_string, [value_ast], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = box_term(value, ctx, block)
    {lower_kernel_to_string(value, Map.fetch!(env, @known_atoms_key), ctx, block), env}
  end

  defp lift_stdlib_call(Kernel, :inspect, [value_ast], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = box_term(value, ctx, block)
    {lower_kernel_inspect(value, :default, Map.fetch!(env, @known_atoms_key), ctx, block), env}
  end

  defp lift_stdlib_call(Kernel, :inspect, [value_ast, [base: :hex]], ctx, block, env) do
    {value, env} = lift_expr(value_ast, ctx, block, env)
    value = box_term(value, ctx, block)
    {lower_kernel_inspect(value, :hex, Map.fetch!(env, @known_atoms_key), ctx, block), env}
  end

  defp lift_stdlib_call(Kernel, :inspect, [_value_ast, opts], _ctx, _block, _env) do
    raise Error,
          "Kernel.inspect/2 supports only the literal option [base: :hex], got: #{inspect(opts)}"
  end

  defp lift_stdlib_call(Enum, :count, [{:.., _, [start_ast, stop_ast]}], ctx, block, env) do
    {start, env} = lift_expr(start_ast, ctx, block, env)
    {stop, env} = lift_expr(stop_ast, ctx, block, env)
    {lift_enum_range_reduce(start, stop, lit(0, ctx, block), 15, ctx, block), env}
  end

  defp lift_stdlib_call(Enum, :to_list, [{:.., _, [start_ast, stop_ast]}], ctx, block, env) do
    {start, env} = lift_expr(start_ast, ctx, block, env)
    {stop, env} = lift_expr(stop_ast, ctx, block, env)

    {
      create_op(
        "ex.enumerable_to_list_range",
        [start, stop],
        [ex_type("term", ctx)],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_stdlib_call(Keyword, :get, [keywords, key], ctx, block, env) do
    lift_stdlib_call(Keyword, :get, [keywords, key, nil], ctx, block, env)
  end

  defp lift_stdlib_call(Keyword, :get, [keywords, key, default], ctx, block, env) do
    {values, env} = lift_operands_boxed([keywords, key, default], ctx, block, env)
    [keywords, key, default] = values
    position = box_term(lit(1, ctx, block), ctx, block)

    found =
      lift_lists_keyfind(
        key,
        position,
        keywords,
        ctx,
        block,
        env[:__budget__],
        env[:__batch_size__]
      )

    value = lift_keyword_value(found, default, ctx, block)
    mark_yield_gate(env[:__budget__], true, value, ctx, block, env)
  end

  defp lift_stdlib_call(:lists, :keyfind, [_, _, _] = args, ctx, block, env) do
    {values, env} = lift_operands_boxed(args, ctx, block, env)
    [key, position, list] = values

    value =
      lift_lists_keyfind(
        key,
        position,
        list,
        ctx,
        block,
        env[:__budget__],
        env[:__batch_size__]
      )

    mark_yield_gate(env[:__budget__], true, value, ctx, block, env)
  end

  defp lift_stdlib_call(:lists, :reverse, [list], ctx, block, env) do
    lift_stdlib_call(:lists, :reverse, [list, []], ctx, block, env)
  end

  defp lift_stdlib_call(:lists, :reverse, [_, _] = args, ctx, block, env) do
    {values, env} = lift_operands_boxed(args, ctx, block, env)
    [list, tail] = values

    value =
      lift_lists_reverse(
        list,
        tail,
        ctx,
        block,
        env[:__budget__],
        env[:__batch_size__]
      )

    mark_yield_gate(env[:__budget__], true, value, ctx, block, env)
  end

  defp lift_stdlib_call(Map, :put, args, ctx, block, env) do
    {values, env} = lift_operands_boxed(args, ctx, block, env)
    {native_term_call(Map, :put, values, ctx, block), env}
  end

  defp lift_stdlib_call(module, fun, args, ctx, block, env) do
    case Batata.Stdlib.class({module, fun, length(args)}) do
      :native_term ->
        {values, env} = lift_operands_boxed(args, ctx, block, env)
        {native_term_call(module, fun, values, ctx, block), env}

      :beamer_callback ->
        raise Error,
              "stdlib call #{inspect(module)}.#{fun}/#{length(args)} requires BEAM callback " <>
                "interop (protocol consolidation), not yet supported"

      :unsupported ->
        raise Error,
              "stdlib call #{inspect(module)}.#{fun}/#{length(args)} is declared but not yet " <>
                "supported in this slice"

      nil ->
        raise Error,
              "unsupported stdlib call: #{inspect(module)}.#{fun}/#{length(args)}"
    end
  end

  # Converts the slice's Gregorian day count to the proleptic Gregorian civil
  # date. This is the constant-time civil-from-days decomposition with an
  # epoch shift from Calendar.ISO day zero (0000-01-01). The adjusted era
  # numerator preserves floor division for dates before the epoch even though
  # `ex.div` truncates toward zero.
  defp lower_date_to_iso8601(days, ctx, block) do
    i64 = integer_type(ctx)
    z = create_op("ex.sub", [days, lit(60, ctx, block)], [i64], ctx, block)
    negative_z = cmp(z, 0, "slt", ctx, block)

    era_numerator =
      select_i64(
        negative_z,
        create_op("ex.sub", [z, lit(146_096, ctx, block)], [i64], ctx, block),
        z,
        ctx,
        block
      )

    era = date_div(era_numerator, 146_097, ctx, block)
    era_days = create_op("ex.mul", [era, lit(146_097, ctx, block)], [i64], ctx, block)
    day_of_era = create_op("ex.sub", [z, era_days], [i64], ctx, block)

    leap4 = date_div(day_of_era, 1_460, ctx, block)
    leap100 = date_div(day_of_era, 36_524, ctx, block)
    leap400 = date_div(day_of_era, 146_096, ctx, block)

    year_numerator =
      day_of_era
      |> date_sub(leap4, ctx, block)
      |> date_add(leap100, ctx, block)
      |> date_sub(leap400, ctx, block)

    year_of_era = date_div(year_numerator, 365, ctx, block)

    base_year =
      create_op(
        "ex.add",
        [year_of_era, create_op("ex.mul", [era, lit(400, ctx, block)], [i64], ctx, block)],
        [i64],
        ctx,
        block
      )

    year_days =
      create_op("ex.mul", [year_of_era, lit(365, ctx, block)], [i64], ctx, block)
      |> date_add(date_div(year_of_era, 4, ctx, block), ctx, block)
      |> date_sub(date_div(year_of_era, 100, ctx, block), ctx, block)

    day_of_year = date_sub(day_of_era, year_days, ctx, block)

    month_prime =
      day_of_year
      |> date_mul(5, ctx, block)
      |> date_add(lit(2, ctx, block), ctx, block)
      |> date_div(153, ctx, block)

    month_days =
      month_prime
      |> date_mul(153, ctx, block)
      |> date_add(lit(2, ctx, block), ctx, block)
      |> date_div(5, ctx, block)

    day =
      day_of_year |> date_sub(month_days, ctx, block) |> date_add(lit(1, ctx, block), ctx, block)

    month_before_march = cmp(month_prime, 10, "slt", ctx, block)

    month =
      select_i64(
        month_before_march,
        date_add(month_prime, lit(3, ctx, block), ctx, block),
        date_sub(month_prime, lit(9, ctx, block), ctx, block),
        ctx,
        block
      )

    year =
      select_i64(
        cmp(month, 2, "sle", ctx, block),
        date_add(base_year, lit(1, ctx, block), ctx, block),
        base_year,
        ctx,
        block
      )

    negative_year = cmp(year, 0, "slt", ctx, block)

    abs_year =
      select_i64(
        negative_year,
        date_sub(lit(0, ctx, block), year, ctx, block),
        year,
        ctx,
        block
      )

    common_bytes =
      four_digits(abs_year, ctx, block) ++
        [lit(?-, ctx, block)] ++
        two_digits(month, ctx, block) ++
        [lit(?-, ctx, block)] ++ two_digits(day, ctx, block)

    negative_year_i1 =
      create_op("arith.trunci", [negative_year], [MLIR.Type.i1()], ctx, block)

    word =
      build_scf_if(
        negative_year_i1,
        ctx,
        block,
        [integer_type(ctx)],
        fn b -> [date_binary([lit(?-, ctx, b) | common_bytes], ctx, b) |> unbox(ctx, b)] end,
        fn b -> [date_binary(common_bytes, ctx, b) |> unbox(ctx, b)] end
      )
      |> hd()

    create_op("ex.to_word", [word], [ex_type("term", ctx)], ctx, block)
  end

  defp four_digits(value, ctx, block) do
    [
      date_div(value, 1_000, ctx, block),
      value |> date_div(100, ctx, block) |> date_rem(10, ctx, block),
      value |> date_div(10, ctx, block) |> date_rem(10, ctx, block),
      date_rem(value, 10, ctx, block)
    ]
    |> Enum.map(&date_digit(&1, ctx, block))
  end

  defp two_digits(value, ctx, block) do
    [date_div(value, 10, ctx, block), date_rem(value, 10, ctx, block)]
    |> Enum.map(&date_digit(&1, ctx, block))
  end

  defp date_digit(value, ctx, block),
    do: date_add(value, lit(?0, ctx, block), ctx, block)

  defp date_binary(bytes, ctx, block) do
    bytes = Enum.map(bytes, &box_term(&1, ctx, block))
    create_term_op("ex.binary", bytes, ctx, block)
  end

  defp date_add(left, right, ctx, block),
    do: create_op("ex.add", [left, right], [integer_type(ctx)], ctx, block)

  defp date_sub(left, right, ctx, block),
    do: create_op("ex.sub", [left, right], [integer_type(ctx)], ctx, block)

  defp date_mul(left, right, ctx, block) when is_integer(right),
    do: date_mul(left, lit(right, ctx, block), ctx, block)

  defp date_mul(left, right, ctx, block),
    do: create_op("ex.mul", [left, right], [integer_type(ctx)], ctx, block)

  defp date_div(left, right, ctx, block) when is_integer(right),
    do: date_div(left, lit(right, ctx, block), ctx, block)

  defp date_div(left, right, ctx, block),
    do: create_op("ex.div", [left, right], [integer_type(ctx)], ctx, block)

  defp date_rem(left, right, ctx, block) when is_integer(right),
    do: date_rem(left, lit(right, ctx, block), ctx, block)

  defp date_rem(left, right, ctx, block),
    do: create_op("ex.rem", [left, right], [integer_type(ctx)], ctx, block)

  defp select_i64(condition, true_value, false_value, ctx, block) do
    condition_i1 = create_op("arith.trunci", [condition], [MLIR.Type.i1()], ctx, block)

    create_op(
      "arith.select",
      [condition_i1, true_value, false_value],
      [integer_type(ctx)],
      ctx,
      block
    )
  end

  # Times use a closed scalar representation in this slice:
  # `((seconds_of_day * 1_000_000 + microsecond) * 10 + precision)`.
  # It preserves the six stored microsecond digits and the independently
  # meaningful display precision without requiring a host `%Time{}` term.
  defp lift_time_new(hour, minute, second, microsecond, precision, ctx, block, env) do
    values = [hour, minute, second, microsecond, precision]

    if Enum.all?(values, &is_integer/1) and hour in 0..23 and minute in 0..59 and
         second in 0..59 and microsecond in 0..999_999 and precision in 0..6 do
      seconds = hour * 3_600 + minute * 60 + second
      packed = (seconds * 1_000_000 + microsecond) * 10 + precision
      {lit(packed, ctx, block), env}
    else
      raise Error, "Time.new requires valid integer literal arguments in this slice"
    end
  end

  # Naive datetimes use a closed, non-negative scalar representation:
  # `((biased_days * 86_400 + seconds_of_day) * 1_000_000 + microsecond) * 10 +
  # precision`, where `biased_days = iso_days + 3_652_059`. The supported Date
  # domain (-9999-01-01 through 9999-12-31) maps to
  # 0..6_311_074_175_999_999_996, which fits in signed i64. Numeric values can
  # overlap other closed slices (for example Time); the registered callee owns
  # their interpretation, so this is not a general tagged-value representation.
  defp lift_naive_datetime_new(args, ctx, block, env) do
    result =
      case normalize_integer_literals(args) do
        {:ok, [year, month, day, hour, minute, second]} ->
          NaiveDateTime.new(year, month, day, hour, minute, second)

        {:ok, [year, month, day, hour, minute, second, microsecond, precision]} ->
          NaiveDateTime.new(
            year,
            month,
            day,
            hour,
            minute,
            second,
            {microsecond, precision}
          )

        _ ->
          :invalid_literals
      end

    case result do
      {:ok, %NaiveDateTime{year: year} = datetime} when year in -9999..9999 ->
        days = Calendar.ISO.date_to_iso_days(datetime.year, datetime.month, datetime.day)
        seconds = datetime.hour * 3_600 + datetime.minute * 60 + datetime.second
        {microsecond, precision} = datetime.microsecond
        biased_days = days + 3_652_059
        packed = ((biased_days * 86_400 + seconds) * 1_000_000 + microsecond) * 10 + precision
        {lit(packed, ctx, block), env}

      _ ->
        raise Error,
              "NaiveDateTime.new requires valid integer literal arguments in this slice"
    end
  end

  defp normalize_integer_literals(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize_integer_literal(value) do
        {:ok, integer} -> {:cont, {:ok, [integer | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp normalize_integer_literal(value) when is_integer(value), do: {:ok, value}
  defp normalize_integer_literal({:-, _, [value]}) when is_integer(value), do: {:ok, -value}
  defp normalize_integer_literal({:+, _, [value]}) when is_integer(value), do: {:ok, value}
  defp normalize_integer_literal(_value), do: :error

  defp lower_naive_datetime_to_iso8601(packed, ctx, block) do
    precision = date_rem(packed, 10, ctx, block)
    payload = date_div(packed, 10, ctx, block)
    microsecond = date_rem(payload, 1_000_000, ctx, block)
    day_seconds = date_div(payload, 1_000_000, ctx, block)
    seconds = date_rem(day_seconds, 86_400, ctx, block)

    days =
      day_seconds
      |> date_div(86_400, ctx, block)
      |> date_sub(lit(3_652_059, ctx, block), ctx, block)

    time_packed =
      seconds
      |> date_mul(1_000_000, ctx, block)
      |> date_add(microsecond, ctx, block)
      |> date_mul(10, ctx, block)
      |> date_add(precision, ctx, block)

    date = lower_date_to_iso8601(days, ctx, block)
    separator = date_binary([lit(?T, ctx, block)], ctx, block)
    time = lower_time_to_iso8601(time_packed, ctx, block)
    iodata = create_term_op("ex.list", [date, separator, time], ctx, block)
    create_op("ex.iodata_to_binary", [iodata], [ex_type("term", ctx)], ctx, block)
  end

  defp lower_time_to_iso8601(packed, ctx, block) do
    precision = date_rem(packed, 10, ctx, block)
    payload = date_div(packed, 10, ctx, block)
    microsecond = date_rem(payload, 1_000_000, ctx, block)
    seconds = date_div(payload, 1_000_000, ctx, block)
    hour = date_div(seconds, 3_600, ctx, block)
    minute = seconds |> date_div(60, ctx, block) |> date_rem(60, ctx, block)
    second = date_rem(seconds, 60, ctx, block)

    base_bytes =
      two_digits(hour, ctx, block) ++
        [lit(?:, ctx, block)] ++
        two_digits(minute, ctx, block) ++
        [lit(?:, ctx, block)] ++ two_digits(second, ctx, block)

    fraction_digits = six_digits(microsecond, ctx, block)
    word = lower_time_precision(precision, base_bytes, fraction_digits, 6, ctx, block)
    create_op("ex.to_word", [word], [ex_type("term", ctx)], ctx, block)
  end

  defp six_digits(value, ctx, block) do
    [
      date_div(value, 100_000, ctx, block),
      value |> date_div(10_000, ctx, block) |> date_rem(10, ctx, block),
      value |> date_div(1_000, ctx, block) |> date_rem(10, ctx, block),
      value |> date_div(100, ctx, block) |> date_rem(10, ctx, block),
      value |> date_div(10, ctx, block) |> date_rem(10, ctx, block),
      date_rem(value, 10, ctx, block)
    ]
    |> Enum.map(&date_digit(&1, ctx, block))
  end

  defp lower_time_precision(_precision, base_bytes, _fraction_digits, 0, ctx, block) do
    date_binary(base_bytes, ctx, block) |> unbox(ctx, block)
  end

  defp lower_time_precision(precision, base_bytes, fraction_digits, digits, ctx, block) do
    matches = cmp(precision, digits, "eq", ctx, block)
    matches_i1 = create_op("arith.trunci", [matches], [MLIR.Type.i1()], ctx, block)

    build_scf_if(
      matches_i1,
      ctx,
      block,
      [integer_type(ctx)],
      fn b ->
        bytes = base_bytes ++ [lit(?., ctx, b)] ++ Enum.take(fraction_digits, digits)
        [date_binary(bytes, ctx, b) |> unbox(ctx, b)]
      end,
      fn b ->
        [lower_time_precision(precision, base_bytes, fraction_digits, digits - 1, ctx, b)]
      end
    )
    |> hd()
  end

  defp monotonic_time_divisor(:native), do: 1
  defp monotonic_time_divisor(:nanosecond), do: 1
  defp monotonic_time_divisor(:microsecond), do: 1_000
  defp monotonic_time_divisor(:millisecond), do: 1_000_000
  defp monotonic_time_divisor(:second), do: 1_000_000_000
  defp monotonic_time_divisor(:minute), do: 60 * 1_000_000_000
  defp monotonic_time_divisor(:hour), do: 3_600 * 1_000_000_000
  defp monotonic_time_divisor(:day), do: 86_400 * 1_000_000_000
  defp monotonic_time_divisor(unit) when is_integer(unit) and unit > 0, do: unit

  defp monotonic_time_divisor(unit) do
    raise Error, "unsupported monotonic_time unit: #{inspect(unit)}"
  end

  # Lowering for `:native_term` registry entries: operands arrive boxed as
  # `!ex.term` words, results are either scalar i64 or `!ex.term`.
  defp lift_lists_keyfind(key, position, list, ctx, block, budget, batch_size) do
    i64 = integer_type(ctx)
    integer? = create_op("ex.is_integer", [position], [i64], ctx, block)
    position_int = create_op("ex.to_int", [position], [i64], ctx, block)
    positive? = cmp(position_int, lit(0, ctx, block), "sgt", ctx, block)
    valid = create_op("arith.andi", [integer?, positive?], [i64], ctx, block)
    valid_i1 = create_op("arith.trunci", [valid], [MLIR.Type.i1()], ctx, block)

    result =
      build_scf_if(
        valid_i1,
        ctx,
        block,
        [i64],
        fn b ->
          false_word = atom_term(false, ctx, b)

          [
            emit_lists_loop(
              :keyfind,
              list,
              false_word,
              {key, position_int},
              ctx,
              b,
              budget,
              batch_size
            )
          ]
        end,
        fn b ->
          [raise_argument_error("invalid :lists.keyfind/3 arguments", ctx, b) |> unbox(ctx, b)]
        end
      )
      |> hd()

    create_op("ex.to_word", [result], [ex_type("term", ctx)], ctx, block)
  end

  defp lift_keyword_value(found, default, ctx, block) do
    i64 = integer_type(ctx)
    tuple? = create_op("ex.is_tuple", [found], [i64], ctx, block)
    tuple_i1 = create_op("arith.trunci", [tuple?], [MLIR.Type.i1()], ctx, block)

    result =
      build_scf_if(
        tuple_i1,
        ctx,
        block,
        [i64],
        fn b ->
          value =
            create_op(
              "ex.tuple_get",
              [found, lit(1, ctx, b)],
              [ex_type("term", ctx)],
              ctx,
              b
            )

          [unbox(value, ctx, b)]
        end,
        fn b -> [unbox(default, ctx, b)] end
      )
      |> hd()

    create_op("ex.to_word", [result], [ex_type("term", ctx)], ctx, block)
  end

  defp lift_lists_reverse(list, tail, ctx, block, budget, batch_size) do
    result = emit_lists_loop(:reverse, list, tail, nil, ctx, block, budget, batch_size)
    create_op("ex.to_word", [result], [ex_type("term", ctx)], ctx, block)
  end

  defp emit_lists_loop(kind, list, initial_acc, match, ctx, block, budget, batch_size) do
    i64 = integer_type(ctx)

    fresh_init = fn b ->
      {
        create_op("ex.unbox", [list], [i64], ctx, b),
        create_op("ex.unbox", [initial_acc], [i64], ctx, b),
        lit(0, ctx, b)
      }
    end

    # The tick lives in the while's before region. Start one step past the
    # requested batch so a fresh/resumed slice executes `batch_size` body
    # iterations before the next preemption check; initializing directly at
    # `batch_size` would make a budget of one yield without any progress.
    state_batch_size = if budget == nil, do: batch_size, else: batch_size + 1
    state = resumable_loop_state(block, ctx, budget, fresh_init, state_batch_size)
    state_count = if budget == nil, do: 3, else: 4
    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), state_count)

    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create(List.duplicate(i64, state_count), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)
    before_args = before_block |> Walker.arguments() |> Enum.to_list()
    [b_current, b_acc, b_cursor | countdown] = before_args

    current_word = create_op("ex.to_word", [b_current], [ex_type("term", ctx)], ctx, before_block)
    nil_word = atom_term(nil, ctx, before_block)
    false_word = atom_term(false, ctx, before_block)
    is_list = create_op("ex.is_list", [current_word], [i64], ctx, before_block)
    is_nil = create_op("ex.term_eq", [current_word, nil_word], [i64], ctx, before_block)
    not_nil = cmp(is_nil, lit(0, ctx, before_block), "eq", ctx, before_block)
    has_cons = create_op("arith.andi", [is_list, not_nil], [i64], ctx, before_block)

    loop_cond =
      case kind do
        :keyfind ->
          acc_word = create_op("ex.to_word", [b_acc], [ex_type("term", ctx)], ctx, before_block)
          not_found = create_op("ex.term_eq", [acc_word, false_word], [i64], ctx, before_block)
          create_op("arith.andi", [has_cons, not_found], [i64], ctx, before_block)

        :reverse ->
          has_cons
      end

    cond_i1 = create_op("arith.trunci", [loop_cond], [MLIR.Type.i1()], ctx, before_block)

    {condition, condition_args} =
      case countdown do
        [] ->
          {cond_i1, before_args}

        [b_countdown] ->
          {budget_cond, next_countdown} =
            inject_reduction_tick(
              before_block,
              ctx,
              cond_i1,
              budget,
              {b_current, b_acc, b_cursor, b_countdown},
              false,
              batch_size
            )

          {budget_cond, [b_current, b_acc, b_cursor, next_countdown]}
      end

    create_op("scf.condition", [condition | condition_args], [], ctx, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create(List.duplicate(i64, state_count), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)
    after_args = after_block |> Walker.arguments() |> Enum.to_list()
    [a_current, a_acc, a_cursor | a_countdown] = after_args
    a_word = create_op("ex.to_word", [a_current], [ex_type("term", ctx)], ctx, after_block)
    head = create_op("ex.list_head", [a_word], [ex_type("term", ctx)], ctx, after_block)
    tail = create_op("ex.list_tail", [a_word], [ex_type("term", ctx)], ctx, after_block)
    next_current = create_op("ex.unbox", [tail], [i64], ctx, after_block)

    next_acc =
      case kind do
        :keyfind ->
          {key, position} = match
          keyfind_accumulator(head, a_acc, key, position, ctx, after_block)

        :reverse ->
          reverse_accumulator(head, a_acc, ctx, after_block)
      end

    next_cursor =
      create_op("ex.add", [a_cursor, lit(1, ctx, after_block)], [i64], ctx, after_block)

    create_op(
      "scf.yield",
      [next_current, next_acc, next_cursor | a_countdown],
      [],
      ctx,
      after_block
    )

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments: Tuple.to_list(state),
        results: List.duplicate(i64, state_count),
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    [final_current, final_acc | _] = while_op |> MLIR.Operation.results() |> Enum.to_list()
    finalize_lists_loop(kind, final_current, final_acc, ctx, block, budget)
  end

  defp keyfind_accumulator(tuple, acc, key, position, ctx, block) do
    i64 = integer_type(ctx)
    tuple? = create_op("ex.is_tuple", [tuple], [i64], ctx, block)
    tuple_length = create_op("ex.tuple_length", [tuple], [i64], ctx, block)
    enough = cmp(tuple_length, position, "sge", ctx, block)
    index = create_op("ex.sub", [position, lit(1, ctx, block)], [i64], ctx, block)
    candidate = create_op("ex.tuple_get", [tuple, index], [ex_type("term", ctx)], ctx, block)
    equal = create_op("ex.term_eq_loose", [candidate, key], [i64], ctx, block)
    tuple_and_size = create_op("arith.andi", [tuple?, enough], [i64], ctx, block)
    matched = create_op("arith.andi", [tuple_and_size, equal], [i64], ctx, block)
    matched_i1 = create_op("arith.trunci", [matched], [MLIR.Type.i1()], ctx, block)
    tuple_i64 = create_op("ex.unbox", [tuple], [i64], ctx, block)
    create_op("arith.select", [matched_i1, tuple_i64, acc], [i64], ctx, block)
  end

  defp reverse_accumulator(head, acc, ctx, block) do
    acc_word = create_op("ex.to_word", [acc], [ex_type("term", ctx)], ctx, block)

    create_op("ex.list_cons", [head, acc_word], [ex_type("term", ctx)], ctx, block)
    |> unbox(ctx, block)
  end

  defp finalize_lists_loop(kind, current, acc, ctx, block, budget) do
    if budget == nil do
      finalize_completed_lists_loop(kind, current, acc, ctx, block)
    else
      pending = create_op("ex.cont_pending", [], [integer_type(ctx)], ctx, block)
      pending_i1 = create_op("arith.trunci", [pending], [MLIR.Type.i1()], ctx, block)

      build_scf_if(pending_i1, ctx, block, [integer_type(ctx)], fn _ -> [acc] end, fn b ->
        [finalize_completed_lists_loop(kind, current, acc, ctx, b)]
      end)
      |> hd()
    end
  end

  defp finalize_completed_lists_loop(kind, current, acc, ctx, block) do
    current_word = create_op("ex.to_word", [current], [ex_type("term", ctx)], ctx, block)
    nil_word = atom_term(nil, ctx, block)
    proper = create_op("ex.term_eq", [current_word, nil_word], [integer_type(ctx)], ctx, block)
    proper_i1 = create_op("arith.trunci", [proper], [MLIR.Type.i1()], ctx, block)

    case kind do
      :reverse ->
        build_scf_if(proper_i1, ctx, block, [integer_type(ctx)], fn _ -> [acc] end, fn b ->
          [raise_argument_error("invalid :lists.reverse/2 list", ctx, b) |> unbox(ctx, b)]
        end)
        |> hd()

      :keyfind ->
        acc_word = create_op("ex.to_word", [acc], [ex_type("term", ctx)], ctx, block)
        false_word = atom_term(false, ctx, block)
        false_i64 = create_op("ex.unbox", [false_word], [integer_type(ctx)], ctx, block)

        not_found =
          create_op("ex.term_eq", [acc_word, false_word], [integer_type(ctx)], ctx, block)

        found = cmp(not_found, lit(0, ctx, block), "eq", ctx, block)
        found_i1 = create_op("arith.trunci", [found], [MLIR.Type.i1()], ctx, block)

        build_scf_if(found_i1, ctx, block, [integer_type(ctx)], fn _ -> [acc] end, fn b ->
          build_scf_if(
            proper_i1,
            ctx,
            b,
            [integer_type(ctx)],
            fn _ -> [false_i64] end,
            fn eb ->
              [raise_argument_error("invalid :lists.keyfind/3 list", ctx, eb) |> unbox(ctx, eb)]
            end
          )
        end)
        |> hd()
    end
  end

  defp raise_argument_error(message, ctx, block) do
    bytes =
      message
      |> :binary.bin_to_list()
      |> Enum.map(fn byte -> box_term(lit(byte, ctx, block), ctx, block) end)

    reason = create_term_op("ex.binary", bytes, ctx, block)
    create_op("ex.raise", [reason, lit(6, ctx, block)], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(module, :length, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :hd, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_head", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(module, :tl, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_tail", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(module, :tuple_size, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Map, :size, [value], ctx, block),
    do: create_op("ex.map_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Map, :put, [map, key, value], ctx, block),
    do: create_op("ex.map_put", [map, key, value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Tuple, :size, [value], ctx, block),
    do: create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :byte_size, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.binary_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :map_size, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.map_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(:binary, :at, [binary, index], ctx, block) do
    index = create_op("ex.to_int", [index], [integer_type(ctx)], ctx, block)
    create_op("ex.binary_get", [binary, index], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(module, :list_to_binary, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.binary_from_list", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(IO, :iodata_to_binary, [value], ctx, block),
    do: create_op("ex.iodata_to_binary", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(:erlang, :iolist_to_binary, [value], ctx, block),
    do: create_op("ex.iodata_to_binary", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Enum, :count, [value], ctx, block),
    do: create_op("ex.enumerable_count", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Enum, :to_list, [value], ctx, block),
    do: create_op("ex.enumerable_to_list", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(String, :length, [value], ctx, block),
    do: create_op("ex.binary_utf8_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(String, :printable?, [value], ctx, block) do
    binary? = create_op("ex.is_binary", [value], [MLIR.Type.i64()], ctx, block)
    condition = create_op("arith.trunci", [binary?], [MLIR.Type.i1()], ctx, block)
    dyn = ex_type("term", ctx)

    build_scf_if(
      condition,
      ctx,
      block,
      [integer_type(ctx)],
      fn b ->
        printable = create_op("ex.string_printable", [value], [MLIR.Type.i64()], ctx, b)
        [unbox(boolean_term(printable, ctx, b), ctx, b)]
      end,
      fn b ->
        payload =
          create_term_op(
            "ex.tuple",
            [
              atom_term(String, ctx, b),
              atom_term(:printable?, ctx, b),
              box_term(lit(2, ctx, b), ctx, b),
              atom_term(nil, ctx, b)
            ],
            ctx,
            b
          )

        raised = create_op("ex.raise", [payload, lit(2, ctx, b)], [dyn], ctx, b)
        [unbox(raised, ctx, b)]
      end
    )
    |> hd()
  end

  defp native_term_call(String, :to_integer, [value], ctx, block),
    do: create_op("ex.string_to_int", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(String, :to_float, [value], ctx, block),
    do: create_op("ex.string_to_float", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Base, :encode16, [value], ctx, block),
    do: create_op("ex.binary_encode16", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Base, :decode16, [value], ctx, block),
    do: create_op("ex.binary_decode16", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Integer, :to_string, [value], ctx, block),
    do: create_op("ex.int_to_string", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Integer, :to_charlist, [value], ctx, block) do
    i64 = integer_type(ctx)
    integer? = create_op("ex.is_integer", [value], [i64], ctx, block)
    integer_i1 = create_op("arith.trunci", [integer?], [MLIR.Type.i1()], ctx, block)

    result =
      build_scf_if(
        integer_i1,
        ctx,
        block,
        [i64],
        fn b ->
          binary = create_op("ex.int_to_string", [value], [ex_type("term", ctx)], ctx, b)
          list = create_op("ex.enumerable_to_list", [binary], [ex_type("term", ctx)], ctx, b)
          [unbox(list, ctx, b)]
        end,
        fn b ->
          message =
            "errors were found at the given arguments:\n\n  * 1st argument: not an integer\n"

          [raise_argument_error(message, ctx, b) |> unbox(ctx, b)]
        end
      )
      |> hd()

    create_op("ex.to_word", [result], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(MapSet, :new, [value], ctx, block),
    do: create_op("ex.mapset_from_list", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(HashSet, :new, [value], ctx, block),
    do: create_op("ex.mapset_from_list", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(MapSet, :member?, [set, member], ctx, block),
    do: create_op("ex.mapset_member", [set, member], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(MapSet, :put, [set, member], ctx, block),
    do: create_op("ex.mapset_put", [set, member], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(Stream, :take, [list, n], ctx, block) do
    n_int = create_op("ex.to_int", [n], [integer_type(ctx)], ctx, block)
    create_op("ex.stream_take", [list, n_int], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(Stream, :drop, [list, n], ctx, block) do
    n_int = create_op("ex.to_int", [n], [integer_type(ctx)], ctx, block)
    create_op("ex.stream_drop", [list, n_int], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(File, :read!, [path], ctx, block),
    do: create_op("ex.file_read", [path], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(File, :stream!, [path], ctx, block),
    do: create_op("ex.file_read_lines", [path], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(_module, :elem, [tuple, index], ctx, block) do
    index_int = create_op("ex.to_int", [index], [MLIR.Type.i64()], ctx, block)
    create_op("ex.tuple_get", [tuple, index_int], [ex_type("term", ctx)], ctx, block)
  end

  defp native_term_call(module, :is_atom, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_atom", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_binary, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_binary", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_integer, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.is_integer", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_float, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.is_float", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_list, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_list", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_map, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_map", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_tuple, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_tuple", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(_module, :first, [value], ctx, block),
    do: create_op("ex.list_head", [value], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(_module, :self, [], ctx, block),
    do: create_op("ex.self", [], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(_module, :send, [pid, msg], ctx, block),
    do: create_op("ex.send", [pid, msg], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(_module, :spawn, [fun], ctx, block),
    do: create_op("ex.spawn", [fun], [ex_type("term", ctx)], ctx, block)

  defp native_term_call(module, :link, [pid], ctx, block) when module in [Process, :erlang] do
    _ =
      create_op(
        "ex.link",
        [pid, atom_term(:EXIT, ctx, block), atom_term(:normal, ctx, block)],
        [ex_type("term", ctx)],
        ctx,
        block
      )

    atom_term(true, ctx, block)
  end

  defp native_term_call(module, :unlink, [pid], ctx, block) when module in [Process, :erlang] do
    _ = create_op("ex.unlink", [pid], [integer_type(ctx)], ctx, block)
    atom_term(true, ctx, block)
  end

  defp native_term_call(module, :exit, [pid, reason], ctx, block)
       when module in [Process, :erlang] do
    _ =
      create_op(
        "ex.exit",
        [pid, reason, atom_term(:EXIT, ctx, block), atom_term(:normal, ctx, block)],
        [ex_type("term", ctx)],
        ctx,
        block
      )

    atom_term(true, ctx, block)
  end

  defp native_term_call(Process, :monitor, [pid], ctx, block) do
    create_op(
      "ex.monitor",
      [
        pid,
        atom_term(:DOWN, ctx, block),
        atom_term(:process, ctx, block),
        atom_term(:normal, ctx, block)
      ],
      [ex_type("term", ctx)],
      ctx,
      block
    )
  end

  defp native_term_call(module, :demonitor, [reference], ctx, block)
       when module in [Process, :erlang] do
    result = create_op("ex.demonitor", [reference], [integer_type(ctx)], ctx, block)
    boolean_term(result, ctx, block)
  end

  defp native_term_call(module, fun, _args, _ctx, _block) do
    raise Error, "no native_term lowering for #{inspect(module)}.#{fun}"
  end

  defp lower_kernel_to_string(value, known_atoms, ctx, block) do
    dyn = ex_type("term", ctx)
    integer? = create_op("ex.is_integer", [value], [MLIR.Type.i64()], ctx, block)
    binary? = create_op("ex.is_binary", [value], [MLIR.Type.i64()], ctx, block)
    atom? = create_op("ex.is_atom", [value], [MLIR.Type.i64()], ctx, block)

    atom_clauses =
      Enum.map(known_atoms, fn {word, atom} ->
        tagged = create_op("ex.to_word", [lit(word, ctx, block)], [dyn], ctx, block)
        equal? = create_op("ex.term_eq", [value, tagged], [MLIR.Type.i64()], ctx, block)

        {equal?,
         fn b ->
           rendered = if is_nil(atom), do: "", else: Atom.to_string(atom)
           {binary, _env} = lift_expr(rendered, ctx, b, %{})
           binary
         end}
      end)

    clauses =
      [
        {integer?, fn b -> create_op("ex.int_to_string", [value], [dyn], ctx, b) end},
        {binary?, fn _b -> value end}
      ] ++
        atom_clauses ++
        [
          {atom?, fn b -> raise_unsupported_to_string(:unknown_atom, value, ctx, b) end},
          {nil, fn b -> raise_unsupported_to_string(:unsupported_type, value, ctx, b) end}
        ]

    region = MLIR.CAPI.mlirRegionCreate()

    Enum.each(clauses, fn {guard, body_fn} ->
      clause_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(region, clause_block)
      clause_args = if guard, do: [guard], else: []
      create_op("ex.clause", clause_args ++ [patterns: pattern_attr([])], [], ctx, clause_block)
      result = body_fn.(clause_block)

      create_op(
        "ex.yield",
        [result, operandSegmentSizes: segment_sizes([1])],
        [],
        ctx,
        clause_block
      )
    end)

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [value, operandSegmentSizes: segment_sizes([1])],
        results: [dyn],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lower_kernel_inspect(value, mode, known_atoms, ctx, block) do
    dyn = ex_type("term", ctx)
    integer? = create_op("ex.is_integer", [value], [MLIR.Type.i64()], ctx, block)
    binary? = create_op("ex.is_binary", [value], [MLIR.Type.i64()], ctx, block)
    atom? = create_op("ex.is_atom", [value], [MLIR.Type.i64()], ctx, block)

    atom_clauses =
      Enum.map(known_atoms, fn {word, atom} ->
        tagged = create_op("ex.to_word", [lit(word, ctx, block)], [dyn], ctx, block)
        equal? = create_op("ex.term_eq", [value, tagged], [MLIR.Type.i64()], ctx, block)

        {equal?,
         fn b ->
           rendered = if atom in [nil, true, false], do: Atom.to_string(atom), else: ":#{atom}"
           {binary, _env} = lift_expr(rendered, ctx, b, %{})
           binary
         end}
      end)

    clauses =
      [
        {integer?,
         fn b ->
           op = if mode == :hex, do: "ex.int_to_hex", else: "ex.int_to_string"
           create_op(op, [value], [dyn], ctx, b)
         end},
        {binary?, fn b -> create_op("ex.binary_quote", [value], [dyn], ctx, b) end}
      ] ++
        atom_clauses ++
        [
          {atom?, fn b -> raise_unsupported_to_string(:unknown_atom, value, ctx, b) end},
          {nil, fn b -> raise_unsupported_to_string(:unsupported_type, value, ctx, b) end}
        ]

    region = MLIR.CAPI.mlirRegionCreate()

    Enum.each(clauses, fn {guard, body_fn} ->
      clause_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(region, clause_block)
      clause_args = if guard, do: [guard], else: []
      create_op("ex.clause", clause_args ++ [patterns: pattern_attr([])], [], ctx, clause_block)
      result = body_fn.(clause_block)

      create_op(
        "ex.yield",
        [result, operandSegmentSizes: segment_sizes([1])],
        [],
        ctx,
        clause_block
      )
    end)

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [value, operandSegmentSizes: segment_sizes([1])],
        results: [dyn],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lower_binary_concat(left, right, both_binary, ctx, block) do
    dyn = ex_type("term", ctx)
    region = MLIR.CAPI.mlirRegionCreate()

    valid_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, valid_block)
    create_op("ex.clause", [both_binary, patterns: pattern_attr([])], [], ctx, valid_block)
    iodata = create_term_op("ex.list", [left, right], ctx, valid_block)
    result = create_op("ex.iodata_to_binary", [iodata], [dyn], ctx, valid_block)
    create_op("ex.yield", [result, operandSegmentSizes: segment_sizes([1])], [], ctx, valid_block)

    fallback_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, fallback_block)
    create_op("ex.clause", [patterns: pattern_attr([])], [], ctx, fallback_block)
    operands = create_term_op("ex.tuple", [left, right], ctx, fallback_block)

    raised =
      create_op("ex.raise", [operands, lit(1, ctx, fallback_block)], [dyn], ctx, fallback_block)

    create_op(
      "ex.yield",
      [raised, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      fallback_block
    )

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [left, operandSegmentSizes: segment_sizes([1])],
        results: [dyn],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lower_exact_map_update(base, updates, ctx, block) do
    dyn = ex_type("term", ctx)
    region = MLIR.CAPI.mlirRegionCreate()
    is_map = create_op("ex.is_map", [base], [MLIR.Type.i64()], ctx, block)
    not_map = cmp(is_map, 0, "eq", ctx, block)

    add_map_update_failure_clause(not_map, base, 5, ctx, region)

    updates
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.each(fn {key, _value} ->
      key_term = atom_term(key, ctx, block)
      fetched = create_op("ex.map_fetch", [base, key_term], [dyn], ctx, block)

      found =
        create_op(
          "ex.tuple_get",
          [fetched, lit(0, ctx, block)],
          [dyn],
          ctx,
          block
        )

      found = create_op("ex.to_int", [found], [MLIR.Type.i64()], ctx, block)
      missing = cmp(found, 0, "eq", ctx, block)
      reason = create_term_op("ex.tuple", [key_term, base], ctx, block)
      add_map_update_failure_clause(missing, reason, 4, ctx, region)
    end)

    success_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, success_block)
    create_op("ex.clause", [patterns: pattern_attr([])], [], ctx, success_block)

    updated =
      Enum.reduce(updates, base, fn {key, value}, map ->
        create_op(
          "ex.map_put",
          [map, atom_term(key, ctx, success_block), value],
          [dyn],
          ctx,
          success_block
        )
      end)

    create_op(
      "ex.yield",
      [updated, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      success_block
    )

    %Beaver.SSA{
      op: "ex.case",
      ip: block,
      ctx: ctx,
      arguments: [base, operandSegmentSizes: segment_sizes([1])],
      results: [dyn],
      loc: MLIR.Location.unknown(),
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
    |> MLIR.Operation.results()
    |> Enum.to_list()
    |> hd()
  end

  defp add_map_update_failure_clause(condition, reason, kind, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    create_op("ex.clause", [condition, patterns: pattern_attr([])], [], ctx, block)

    raised =
      create_op("ex.raise", [reason, lit(kind, ctx, block)], [ex_type("term", ctx)], ctx, block)

    create_op(
      "ex.yield",
      [raised, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      block
    )
  end

  defp lower_short_circuit_and(left, right_ast, falsy, env, ctx, block) do
    dyn = ex_type("term", ctx)
    region = MLIR.CAPI.mlirRegionCreate()

    falsy_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, falsy_block)
    create_op("ex.clause", [falsy, patterns: pattern_attr([])], [], ctx, falsy_block)
    create_op("ex.yield", [left, operandSegmentSizes: segment_sizes([1])], [], ctx, falsy_block)

    truthy_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, truthy_block)
    create_op("ex.clause", [patterns: pattern_attr([])], [], ctx, truthy_block)
    {right, _right_env} = lift_expr(right_ast, ctx, truthy_block, env)
    right = box_term(lift_value(right, ctx, truthy_block, env), ctx, truthy_block)

    create_op(
      "ex.yield",
      [right, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      truthy_block
    )

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [left, operandSegmentSizes: segment_sizes([1])],
        results: [dyn],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lower_body_if(condition, then_ast, else_ast, falsy, env, ctx, block) do
    dyn = ex_type("term", ctx)
    region = MLIR.CAPI.mlirRegionCreate()

    falsy_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, falsy_block)
    create_op("ex.clause", [falsy, patterns: pattern_attr([])], [], ctx, falsy_block)
    {else_value, else_env} = lift_expr(else_ast, ctx, falsy_block, env)
    else_value = box_term(lift_value(else_value, ctx, falsy_block, else_env), ctx, falsy_block)

    create_op(
      "ex.yield",
      [else_value, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      falsy_block
    )

    truthy_block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, truthy_block)
    create_op("ex.clause", [patterns: pattern_attr([])], [], ctx, truthy_block)
    {then_value, then_env} = lift_expr(then_ast, ctx, truthy_block, env)
    then_value = box_term(lift_value(then_value, ctx, truthy_block, then_env), ctx, truthy_block)

    create_op(
      "ex.yield",
      [then_value, operandSegmentSizes: segment_sizes([1])],
      [],
      ctx,
      truthy_block
    )

    %Beaver.SSA{
      op: "ex.case",
      ip: block,
      ctx: ctx,
      arguments: [condition, operandSegmentSizes: segment_sizes([1])],
      results: [dyn],
      loc: MLIR.Location.unknown(),
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
    |> MLIR.Operation.results()
    |> Enum.to_list()
    |> hd()
  end

  defp term_falsy_condition(value, ctx, block) do
    false_term = atom_term(false, ctx, block)
    nil_term = atom_term(nil, ctx, block)
    false? = create_op("ex.term_eq", [value, false_term], [MLIR.Type.i64()], ctx, block)
    nil? = create_op("ex.term_eq", [value, nil_term], [MLIR.Type.i64()], ctx, block)
    create_op("arith.ori", [false?, nil?], [MLIR.Type.i64()], ctx, block)
  end

  defp lower_if_truthiness(condition_ast, condition, ctx, block) do
    if boolean_scalar_ast?(condition_ast) do
      {condition, cmp(condition, 0, "eq", ctx, block)}
    else
      condition =
        if term_operand?(condition) do
          condition
        else
          create_op("ex.to_word", [condition], [ex_type("term", ctx)], ctx, block)
        end

      {condition, term_falsy_condition(condition, ctx, block)}
    end
  end

  defp boolean_scalar_ast?({name, _, [_arg]})
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer, :is_float],
       do: true

  defp boolean_scalar_ast?({op, _, [_left, _right]})
       when op in [:==, :!=, :===, :!==, :<, :<=, :>, :>=],
       do: true

  defp boolean_scalar_ast?(_ast), do: false

  defp raise_unsupported_to_string(reason, value, ctx, block) do
    reported_value = if reason == :unknown_atom, do: atom_term(reason, ctx, block), else: value

    payload =
      create_term_op(
        "ex.tuple",
        [atom_term(reason, ctx, block), reported_value],
        ctx,
        block
      )

    create_op("ex.raise", [payload, lit(3, ctx, block)], [ex_type("term", ctx)], ctx, block)
  end

  defp resolve_fun_ref({name, _, nil}, env) when is_atom(name) do
    case Map.get(env, name) do
      {:fn_ref, fn_idx, fn_name, arity, captured} -> {:ok, fn_idx, fn_name, arity, captured}
      nil -> :error
      value -> {:dynamic, value}
    end
  end

  defp resolve_fun_ref({:__fn_ref__, _, [fn_idx, name, arity, captured]}, _env),
    do: {:ok, fn_idx, name, arity, captured}

  defp resolve_fun_ref(_ast, _env), do: :error

  # Reads the captured variable values of a compile-time function reference
  # from the current env.
  defp resolve_captured(captured, env) do
    Enum.map(captured, fn var ->
      case Map.fetch(env, var) do
        {:ok, value} -> value
        :error -> raise Error, "unbound variable reference: #{inspect(var)}"
      end
    end)
  end

  # Materializes a compile-time function reference into a first-class closure
  # word; all other values pass through unchanged.
  defp lift_value({:fn_ref, fn_idx, _name, arity, captured}, ctx, block, env) do
    env_values = resolve_captured(captured, env)

    unless length(env_values) <= 4 do
      raise Error, "anonymous function capture exceeds 4 slots: #{length(env_values)}"
    end

    create_op(
      "ex.make_fun_with_arity",
      env_values ++
        [
          fn_idx: MLIR.Attribute.integer(MLIR.Type.i64(), fn_idx),
          arity: MLIR.Attribute.integer(MLIR.Type.i64(), arity),
          env_len: MLIR.Attribute.integer(MLIR.Type.i64(), length(captured)),
          operandSegmentSizes:
            segment_sizes(
              List.duplicate(1, length(captured)) ++ List.duplicate(0, 4 - length(captured))
            )
        ],
      [ex_type("term", ctx)],
      ctx,
      block
    )
  end

  defp lift_value(value, _ctx, _block, _env), do: value

  defp zero_i64(ctx, block) do
    create_op(
      "ex.lit",
      [value: MLIR.Attribute.integer(MLIR.Type.i64(), 0)],
      [MLIR.Type.i64()],
      ctx,
      block
    )
  end

  defp lift_tuple_literal(tuple, ctx, block, env) do
    {values, env} = lift_operands_boxed(Tuple.to_list(tuple), ctx, block, env)
    {create_term_op("ex.tuple", values, ctx, block), env}
  end

  defp cmp_predicate(:==), do: "eq"
  defp cmp_predicate(:!=), do: "ne"
  defp cmp_predicate(:===), do: "eq"
  defp cmp_predicate(:!==), do: "ne"
  defp cmp_predicate(:<), do: "slt"
  defp cmp_predicate(:<=), do: "sle"
  defp cmp_predicate(:>), do: "sgt"
  defp cmp_predicate(:>=), do: "sge"

  defp lift_case(clauses, scrutinee, env, ctx, block, opts \\ []) do
    term_case? =
      Keyword.get_lazy(opts, :term_case?, fn ->
        Enum.any?(clauses, &(clause_pattern(&1) |> term_pattern?()))
      end)

    clauses = ensure_case_fallback(clauses, Keyword.put(opts, :term_case?, term_case?))

    if term_case? do
      lift_term_case(clauses, scrutinee, env, ctx, block, opts)
    else
      lift_scalar_case(clauses, scrutinee, env, ctx, block, opts)
    end
  end

  defp ensure_case_fallback(clauses, opts) do
    if Enum.any?(clauses, &clause_catch_all?/1) and
         not Keyword.get(opts, :force_fallback, false) do
      clauses
    else
      unmatched = {:__batata_unmatched__, [], nil}
      reason = Keyword.get(opts, :failure_reason, unmatched)
      kind = Keyword.get(opts, :failure_kind, 1)

      marker =
        if Keyword.fetch!(opts, :term_case?),
          do: :__batata_raise__,
          else: :__batata_raise_scalar__

      clauses ++ [{:->, [], [[unmatched], {marker, kind, reason}]}]
    end
  end

  defp clause_catch_all?({:->, _, [[{name, _, nil}], _body]}) when is_atom(name), do: true
  defp clause_catch_all?(_clause), do: false

  defp lift_scalar_case(clauses, scrutinee, env, ctx, block, opts) do
    parsed = Enum.map(clauses, &parse_clause/1)
    clause_bindss = case_clause_bindss(opts, length(parsed))
    extra_clause_conds = case_clause_conditions(opts, length(parsed))

    unless parsed |> List.last() |> Map.fetch!(:patterns) == [] do
      raise Error, "case requires a final catch-all clause"
    end

    guards =
      parsed
      |> Enum.zip(clause_bindss)
      |> Enum.zip(extra_clause_conds)
      |> Enum.map(fn {{clause, clause_binds}, extra_clause_cond} ->
        clause_env = Map.merge(env, Map.new(clause_binds))

        guard_cond =
          case clause.guard do
            nil -> nil
            guard_ast -> lift_guard(guard_ast, clause.vars, scrutinee, clause_env, ctx, block)
          end

        combine([guard_cond, extra_clause_cond], ctx, block)
      end)

    region = MLIR.CAPI.mlirRegionCreate()

    yield_types =
      parsed
      |> Enum.zip(guards)
      |> Enum.zip(clause_bindss)
      |> Enum.map(fn {{clause, guard}, clause_binds} ->
        add_clause_block(clause, guard, scrutinee, clause_binds, env, ctx, region)
      end)

    [first_type | rest_types] = yield_types

    unless Keyword.get(opts, :relax_types, false) or
             Enum.all?(rest_types, &MLIR.equal?(first_type, &1)) do
      raise Error, "case clauses must yield the same type"
    end

    result_type = first_type

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [scrutinee, operandSegmentSizes: segment_sizes([1])],
        results: [result_type],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lift_term_case(clauses, scrutinee, env, ctx, block, opts) do
    parsed = Enum.map(clauses, &parse_term_clause/1)
    clause_bindss = case_clause_bindss(opts, length(parsed))
    extra_clause_conds = case_clause_conditions(opts, length(parsed))

    unless match?(
             {name, _, nil} when is_atom(name),
             parsed |> List.last() |> Map.fetch!(:pattern)
           ) do
      raise Error, "case requires a final catch-all clause"
    end

    # term reads require a tagged word, so box the scrutinee once up front
    # (a no-op for values that already are terms). Multi-clause function
    # arguments already carry the tagged word, so they are re-typed with
    # ex.to_word instead (pure passthrough, no re-tagging).
    scrutinee =
      if Keyword.get(opts, :box_scrutinee, true) do
        box_term(scrutinee, ctx, block)
      else
        create_op("ex.to_word", [scrutinee], [ex_type("term", ctx)], ctx, block)
      end

    {guards, bindss} =
      parsed
      |> Enum.zip(clause_bindss)
      |> Enum.zip(extra_clause_conds)
      |> Enum.map(fn {{clause, clause_binds}, extra_clause_cond} ->
        {match_cond, pattern_binds} =
          build_match(
            clause.pattern,
            scrutinee,
            ctx,
            block,
            clause.guard == nil,
            Map.get(env, @struct_schema_key)
          )

        {match_cond, binds} =
          reconcile_term_bindings(match_cond, clause_binds, pattern_binds, ctx, block)

        guard_cond =
          case clause.guard do
            nil ->
              nil

            guard_ast ->
              lift_term_guard(guard_ast, binds, env, ctx, block)
          end

        {combine([match_cond, guard_cond, extra_clause_cond], ctx, block), binds}
      end)
      |> Enum.unzip()

    # An explicit `is_integer(x)` guard refines the bound word for the clause
    # body. Without that proof term values remain dynamic and integer
    # arithmetic rejects them before invalid IR can be created.
    bindss = untag_int_binds(parsed, bindss, ctx, block)

    region = MLIR.CAPI.mlirRegionCreate()

    yield_types =
      parsed
      |> Enum.zip(guards)
      |> Enum.zip(bindss)
      |> Enum.map(fn {{clause, guard}, binds} ->
        add_term_clause_block(clause, guard, binds, env, ctx, region)
      end)

    [first_type | rest_types] = yield_types

    unless Keyword.get(opts, :relax_types, false) or
             Enum.all?(rest_types, &MLIR.equal?(first_type, &1)) do
      raise Error, "case clauses must yield the same type"
    end

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [scrutinee, operandSegmentSizes: segment_sizes([1])],
        results: [first_type],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp case_clause_bindss(opts, clause_count) do
    case Keyword.fetch(opts, :clause_bindss) do
      :error ->
        List.duplicate([], clause_count)

      {:ok, bindss} when length(bindss) == clause_count ->
        bindss

      {:ok, bindss} when length(bindss) + 1 == clause_count ->
        bindss ++ [Keyword.get(opts, :fallback_binds, [])]

      {:ok, bindss} ->
        raise Error,
              "case clause binding count mismatch: #{length(bindss)} bindings for #{clause_count} clauses"
    end
  end

  defp case_clause_conditions(opts, clause_count) do
    case Keyword.fetch(opts, :extra_clause_conds) do
      :error ->
        List.duplicate(nil, clause_count)

      {:ok, conditions} when length(conditions) == clause_count ->
        conditions

      {:ok, conditions} when length(conditions) + 1 == clause_count ->
        conditions ++ [nil]

      {:ok, conditions} ->
        raise Error,
              "case clause condition count mismatch: #{length(conditions)} conditions for " <>
                "#{clause_count} clauses"
    end
  end

  defp reconcile_term_bindings(match_cond, clause_binds, pattern_binds, ctx, block) do
    {conds, binds, _seen} =
      Enum.reduce(clause_binds ++ pattern_binds, {[], [], %{}}, fn binding, acc ->
        reconcile_term_binding(binding, acc, ctx, block)
      end)

    {combine([match_cond | conds], ctx, block), Enum.reverse(binds)}
  end

  defp reconcile_term_binding({name, value}, {conds, binds, seen}, ctx, block) do
    case Map.fetch(seen, name) do
      :error ->
        {conds, [{name, value} | binds], Map.put(seen, name, value)}

      {:ok, bound} ->
        bound = create_op("ex.to_word", [bound], [ex_type("term", ctx)], ctx, block)

        equality =
          create_op(
            "ex.term_eq",
            [bound, box_if_scalar(value, ctx, block)],
            [MLIR.Type.i64()],
            ctx,
            block
          )

        binds =
          Enum.map(binds, fn {var, current} ->
            {var, if(var == name, do: value, else: current)}
          end)

        {[equality | conds], binds, Map.put(seen, name, value)}
    end
  end

  defp untag_int_binds(parsed, bindss, ctx, block) do
    parsed
    |> Enum.zip(bindss)
    |> Enum.map(&untag_clause_int_binds(&1, ctx, block))
  end

  defp untag_clause_int_binds({%{guard: guard}, binds}, ctx, block) do
    integer_vars = integer_guard_vars(guard)
    Enum.map(binds, &untag_int_bind(&1, integer_vars, ctx, block))
  end

  defp untag_int_bind({var, value}, integer_vars, ctx, block) do
    if MapSet.member?(integer_vars, var) do
      {var, create_op("ex.to_int", [value], [MLIR.Type.i64()], ctx, block)}
    else
      {var, value}
    end
  end

  # Receive lowering currently narrows one exact `is_integer/1` guard. Keep
  # that scalar helper separate from the richer term-clause guard inventory.
  defp integer_guard_var({:is_integer, _, [{var, _, nil}]}) when is_atom(var), do: var
  defp integer_guard_var(_guard), do: nil

  defp integer_guard_vars(nil), do: MapSet.new()

  defp integer_guard_vars(guard) do
    {_guard, vars} =
      Macro.prewalk(guard, MapSet.new(), fn
        {:is_integer, _, [{var, _, _}]} = ast, vars when is_atom(var) ->
          {ast, MapSet.put(vars, var)}

        {:in, _, [{var, _, _}, values]} = ast, vars when is_atom(var) ->
          if GuardSupport.integer_members(values),
            do: {ast, MapSet.put(vars, var)},
            else: {ast, vars}

        ast, vars ->
          {ast, vars}
      end)

    vars
  end

  # The match condition and the bound values of one term pattern are computed
  # eagerly before `ex.case`: predicates and reads are pure and safe on the
  # wrong term kind (reads return nil), so a non-matching clause's eager
  # values are simply unused. The combined condition becomes the clause guard.
  # `defer_rest?` moves the rest-slice materialization of a top-level binary
  # pattern into the clause body (expandable 210418e): without a guard, the
  # slice is only needed when the clause matches, so a rejected clause never
  # allocates it.
  defp build_match(pattern, value, ctx, block, defer_rest?, struct_schema) do
    pattern = normalize_struct_patterns(pattern, struct_schema)

    case pattern do
      {:<<>>, _, segments} -> build_binary_match(segments, value, ctx, block, defer_rest?)
      _ -> do_build_match(pattern, value, ctx, block)
    end
  end

  defp normalize_struct_patterns(pattern, struct_schemas) do
    Macro.prewalk(pattern, fn
      {:%, _, [{:__aliases__, _, module_parts}, {:%{}, map_meta, fields}]} = struct_pattern ->
        module = Elixir.Module.concat(module_parts)

        schema =
          case resolve_struct_schema(module, struct_schemas) do
            {:ok, schema} ->
              schema

            :error ->
              raise Error,
                    "struct pattern requires the current-module schema or registered schema, got: #{inspect(module)}"
          end

        unless is_list(fields) and Enum.all?(fields, &match?({key, _} when is_atom(key), &1)) do
          raise Error, "struct patterns require literal atom fields: #{inspect(struct_pattern)}"
        end

        declared = MapSet.new(schema.fields, &elem(&1, 0))

        case fields |> Keyword.keys() |> Enum.reject(&MapSet.member?(declared, &1)) do
          [] -> {:%{}, map_meta, [__struct__: module] ++ fields}
          unknown -> raise Error, "unknown struct pattern fields: #{inspect(Enum.sort(unknown))}"
        end

      other ->
        other
    end)
  end

  defp resolve_struct_schema(module, %Frontend.StructSchema{module: mod} = schema)
       when module == mod,
       do: {:ok, schema}

  defp resolve_struct_schema(module, %{} = schemas), do: Map.fetch(schemas, module)
  defp resolve_struct_schema(_module, _), do: :error

  defp do_build_match({name, _, nil}, value, _ctx, _block) when is_atom(name) do
    if name == :_ do
      {nil, []}
    else
      {nil, [{name, value}]}
    end
  end

  defp do_build_match({:=, _, [left, right]} = alias_pattern, value, ctx, block) do
    {subpattern, alias_name} = pattern_alias_parts!(left, right, alias_pattern)
    {cond, binds} = do_build_match(subpattern, value, ctx, block)

    if alias_name == :_ do
      {cond, binds}
    else
      if Keyword.has_key?(binds, alias_name) do
        raise Error, "pattern alias repeats binding: #{inspect(alias_name)}"
      end

      {cond, binds ++ [{alias_name, value}]}
    end
  end

  # An atom literal pattern (`receive do :urgent -> ... end`): compare the
  # scrutinee word against the atom's deterministic hash word.
  defp do_build_match(atom, value, ctx, block) when is_atom(atom) do
    word = lit(atom_word(atom), ctx, block)
    word_dyn = create_op("ex.to_word", [word], [ex_type("term", ctx)], ctx, block)

    cond =
      create_op(
        "ex.term_eq",
        [value, word_dyn],
        [MLIR.Type.i64()],
        ctx,
        block
      )

    {cond, []}
  end

  defp do_build_match(integer, value, ctx, block) when is_integer(integer) do
    lit =
      create_op(
        "ex.lit",
        [value: MLIR.Attribute.integer(MLIR.Type.i64(), integer)],
        [MLIR.Type.i64()],
        ctx,
        block
      )

    boxed = box_term(lit, ctx, block)
    {create_op("ex.term_eq", [value, boxed], [MLIR.Type.i64()], ctx, block), []}
  end

  defp do_build_match(tuple, value, ctx, block) when is_tuple(tuple) and tuple_size(tuple) != 3 do
    build_tuple_match(Tuple.to_list(tuple), value, ctx, block)
  end

  defp do_build_match({a, b, c}, value, ctx, block)
       when not (is_atom(a) and is_list(b) and is_list(c)) do
    build_tuple_match([a, b, c], value, ctx, block)
  end

  defp do_build_match({:{}, _, elements}, value, ctx, block) do
    build_tuple_match(elements, value, ctx, block)
  end

  defp do_build_match({:%{}, _, entries}, value, ctx, block) do
    build_map_match(entries, value, ctx, block)
  end

  defp do_build_match({:<<>>, _, segments}, value, ctx, block) do
    build_binary_match(segments, value, ctx, block)
  end

  defp do_build_match([], value, ctx, block) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        0,
        "eq",
        ctx,
        block
      )

    {combine([cond_list, cond_len], ctx, block), []}
  end

  defp do_build_match([{:|, _, [head, tail]}], value, ctx, block) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_nonempty =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        0,
        "ne",
        ctx,
        block
      )

    head_value = create_op("ex.list_head", [value], [ex_type("term", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("term", ctx)], ctx, block)
    {head_cond, head_binds} = do_build_match(head, head_value, ctx, block)
    {tail_cond, tail_binds} = do_build_match(tail, tail_value, ctx, block)

    {combine([cond_list, cond_nonempty, head_cond, tail_cond], ctx, block),
     head_binds ++ tail_binds}
  end

  defp do_build_match(elements, value, ctx, block) when is_list(elements) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        length(elements),
        "eq",
        ctx,
        block
      )

    {elem_conds, binds} = list_elements_match(elements, value, ctx, block, [])
    {combine([cond_list, cond_len | elem_conds], ctx, block), binds}
  end

  defp do_build_match(other, _value, _ctx, _block) do
    raise Error, "unsupported term pattern: #{inspect(other)}"
  end

  defp build_tuple_match(elements, value, ctx, block) do
    cond_tuple =
      create_op("ex.is_tuple", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block),
        length(elements),
        "eq",
        ctx,
        block
      )

    {elem_conds, binds} =
      elements
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {element, index}, binds ->
        element_value =
          create_op(
            "ex.tuple_get",
            [value, lit(index, ctx, block)],
            [ex_type("term", ctx)],
            ctx,
            block
          )

        {cond, element_binds} = do_build_match(element, element_value, ctx, block)
        {cond, element_binds ++ binds}
      end)

    {combine([cond_tuple, cond_len | elem_conds], ctx, block), Enum.reverse(binds)}
  end

  defp build_map_match(entries, value, ctx, block) do
    unless Enum.all?(entries, &atom_keyed_map_pattern_entry?/1) do
      raise Error,
            "map patterns only support atom literal keys: #{inspect(entries)}"
    end

    cond_map = create_op("ex.is_map", [value], [MLIR.Type.i64()], ctx, block)

    {conds, binds} =
      Enum.map_reduce(entries, [], fn {key, pattern}, binds ->
        key_word =
          create_op(
            "ex.to_word",
            [lit(atom_word(key), ctx, block)],
            [ex_type("term", ctx)],
            ctx,
            block
          )

        fetched = create_op("ex.map_fetch", [value, key_word], [ex_type("term", ctx)], ctx, block)

        found =
          create_op(
            "ex.tuple_get",
            [fetched, lit(0, ctx, block)],
            [ex_type("term", ctx)],
            ctx,
            block
          )

        fetched_value =
          create_op(
            "ex.tuple_get",
            [fetched, lit(1, ctx, block)],
            [ex_type("term", ctx)],
            ctx,
            block
          )

        found_int = create_op("ex.to_int", [found], [MLIR.Type.i64()], ctx, block)
        found_cond = cmp(found_int, 1, "eq", ctx, block)
        {value_cond, value_binds} = do_build_match(pattern, fetched_value, ctx, block)
        {combine([found_cond, value_cond], ctx, block), value_binds ++ binds}
      end)

    {combine([cond_map | conds], ctx, block), Enum.reverse(binds)}
  end

  defp atom_keyed_map_pattern_entry?({key, _pattern}) when is_atom(key), do: true
  defp atom_keyed_map_pattern_entry?(_entry), do: false

  defp pattern_alias_parts!(left, right, alias_pattern) do
    case {pattern_variable_name(left), pattern_variable_name(right)} do
      {nil, name} when is_atom(name) ->
        {left, name}

      {name, nil} when is_atom(name) ->
        {right, name}

      _ ->
        raise Error, "pattern alias requires exactly one variable side: #{inspect(alias_pattern)}"
    end
  end

  defp pattern_variable_name({name, _, nil}) when is_atom(name), do: name
  defp pattern_variable_name(_pattern), do: nil

  defp list_elements_match([], _value, _ctx, _block, binds), do: {[], binds}

  defp list_elements_match([element | rest], value, ctx, block, binds) do
    head_value = create_op("ex.list_head", [value], [ex_type("term", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("term", ctx)], ctx, block)
    {head_cond, head_binds} = do_build_match(element, head_value, ctx, block)
    {tail_conds, tail_binds} = list_elements_match(rest, tail_value, ctx, block, binds)
    {[head_cond | tail_conds], head_binds ++ tail_binds}
  end

  defp build_binary_match(segments, value, ctx, block, defer_rest? \\ false) do
    {segs, rest} = parse_binary_segments(segments)

    cond_bin =
      create_op("ex.is_binary", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    {conds, binds, offset} =
      Enum.reduce(segs, {[], [], lit(0, ctx, block)}, fn seg, {conds, binds, offset} ->
        case seg do
          {:byte, pat} ->
            byte_value =
              create_op(
                "ex.binary_get",
                [value, offset],
                [ex_type("term", ctx)],
                ctx,
                block
              )

            {cond, pat_binds} = do_build_match(pat, byte_value, ctx, block)

            next =
              create_op("ex.add", [offset, lit(1, ctx, block)], [MLIR.Type.i64()], ctx, block)

            {[cond | conds], pat_binds ++ binds, next}

          {:utf8, pat} ->
            width =
              create_op("ex.binary_utf8_width", [value, offset], [MLIR.Type.i64()], ctx, block)

            codepoint =
              create_op("ex.binary_utf8_get", [value, offset], [ex_type("term", ctx)], ctx, block)

            cond_w = cmp(width, 0, "ne", ctx, block)
            {pat_cond, pat_binds} = do_build_match(pat, codepoint, ctx, block)
            next = create_op("ex.add", [offset, width], [MLIR.Type.i64()], ctx, block)
            {[cond_w, pat_cond | conds], pat_binds ++ binds, next}
        end
      end)

    {rest_cond, rest_binds} = build_rest_bind(rest, value, offset, ctx, block, defer_rest?)

    cond_len =
      cmp(
        create_op("ex.binary_length", [value], [MLIR.Type.i64()], ctx, block),
        offset,
        if(rest == nil, do: "eq", else: "sge"),
        ctx,
        block
      )

    {combine([cond_bin, cond_len | Enum.reverse(conds) ++ [rest_cond]], ctx, block),
     Enum.reverse(binds) ++ rest_binds}
  end

  defp build_rest_bind(nil, _value, _offset, _ctx, _block, _defer_rest?), do: {nil, []}

  defp build_rest_bind({name, _, nil}, value, offset, ctx, _block, true)
       when is_atom(name) and name != :_ do
    slice = fn clause_block ->
      create_op("ex.binary_slice", [value, offset], [ex_type("term", ctx)], ctx, clause_block)
    end

    {nil, [{name, {:deferred, slice}}]}
  end

  defp build_rest_bind(rest_pat, value, offset, ctx, block, _defer_rest?) do
    rest_value =
      create_op("ex.binary_slice", [value, offset], [ex_type("term", ctx)], ctx, block)

    do_build_match(rest_pat, rest_value, ctx, block)
  end

  defp parse_binary_segments(segments) do
    {segs, rest} =
      Enum.split_while(segments, &(not match?({:"::", _, [_, {:binary, _, nil}]}, &1)))

    case rest do
      [] ->
        {Enum.map(segs, &binary_segment!/1), nil}

      [{:"::", _, [rest_pat, {:binary, _, nil}]}] ->
        {Enum.map(segs, &binary_segment!/1), rest_pat}

      _ ->
        raise Error, "binary rest segment must be the last segment: #{inspect(segments)}"
    end
  end

  defp binary_segment!({:"::", _, [pat, 8]}), do: {:byte, pat}
  defp binary_segment!({:"::", _, [pat, {:utf8, _, nil}]}), do: {:utf8, pat}
  defp binary_segment!(pat) when is_integer(pat), do: {:byte, pat}
  defp binary_segment!({name, _, nil} = pat) when is_atom(name), do: {:byte, pat}

  defp binary_segment!(segment) do
    raise Error, "unsupported binary segment: #{inspect(segment)}"
  end

  defp add_term_clause_block(clause, guard, binds, env, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    clause_args = if guard, do: [guard], else: []
    create_op("ex.clause", clause_args ++ [patterns: pattern_attr([])], [], ctx, block)

    clause_env =
      Enum.reduce(binds, env, fn
        {var, {:deferred, fun}}, acc -> Map.put(acc, var, fun.(block))
        {var, value}, acc -> Map.put(acc, var, value)
      end)

    # A clause body is one AST expression even when that expression is [] or
    # a non-empty list literal. List.wrap/1 erases [] and expands list literals
    # into multiple block expressions, so keep the AST in a singleton block.
    {value, clause_env} = lift_block([clause.body], ctx, block, clause_env)
    value = lift_value(value, ctx, block, clause_env)
    create_op("ex.yield", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    MLIR.Value.type(value)
  end

  defp combine(conds, ctx, block) do
    conds
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      [single] ->
        single

      many ->
        Enum.reduce(many, fn cond, acc ->
          create_op("arith.andi", [acc, cond], [MLIR.Type.i64()], ctx, block)
        end)
    end
  end

  # Term-pattern guards are evaluated eagerly against the (nil-safe) bound
  # values, so they must be composed of term-safe predicates only: `is_*`
  # calls and explicitly supported integer expressions on bound or outer
  # variables. Other term operations are rejected explicitly.
  defp lift_term_guard(guard_ast, binds, env, ctx, block) do
    unless GuardSupport.compiler_supported?(guard_ast) do
      raise Error,
            "unsupported guard on term pattern (only is_* predicates on bound or outer variables): " <>
              inspect(guard_ast)
    end

    guard_env = Map.merge(env, Map.new(binds))
    lift_term_guard_expr(guard_ast, guard_env, ctx, block)
  end

  defp lift_term_guard_expr({:in, _, [{name, _, _}, members]}, env, ctx, block)
       when is_atom(name) do
    values = GuardSupport.term_members(members)
    value = Map.fetch!(env, name)
    word = box_if_scalar(value, ctx, block)

    lower_term_membership(word, values, ctx, block)
  end

  defp lift_term_guard_expr({:is_function, _, [{name, _, _}]}, env, ctx, block)
       when is_atom(name) do
    word = env |> Map.fetch!(name) |> lift_value(ctx, block, env) |> box_if_scalar(ctx, block)
    arity = create_op("ex.fun_arity", [word], [MLIR.Type.i64()], ctx, block)
    cmp(arity, 0, "sge", ctx, block)
  end

  defp lift_term_guard_expr({:is_function, _, [{name, _, _}, expected]}, env, ctx, block)
       when is_atom(name) and is_integer(expected) and expected >= 0 and expected <= 4 do
    word = env |> Map.fetch!(name) |> lift_value(ctx, block, env) |> box_if_scalar(ctx, block)
    arity = create_op("ex.fun_arity", [word], [MLIR.Type.i64()], ctx, block)
    cmp(arity, expected, "eq", ctx, block)
  end

  defp lift_term_guard_expr({op, _, [left, right]}, env, ctx, block)
       when op in [:and, :andalso, :or, :orelse] do
    left = lift_term_guard_expr(left, env, ctx, block)
    right = lift_term_guard_expr(right, env, ctx, block)
    mlir_op = if op in [:and, :andalso], do: "arith.andi", else: "arith.ori"
    create_op(mlir_op, [left, right], [MLIR.Type.i64()], ctx, block)
  end

  defp lift_term_guard_expr({op, _, [left, right]}, env, ctx, block)
       when op in [:<, :<=, :>, :>=] do
    lower_integer_guard_comparison(left, right, op, env, ctx, block)
  end

  defp lift_term_guard_expr({op, _, [left, right]} = guard_ast, env, ctx, block)
       when op in [:==, :!=, :===, :!==] do
    if integer_guard_call?(left) or integer_guard_call?(right) do
      lower_integer_guard_comparison(left, right, op, env, ctx, block)
    else
      {value, _env} = lift_expr(guard_ast, ctx, block, env)
      value
    end
  end

  defp lift_term_guard_expr(guard_ast, env, ctx, block) do
    {value, _env} = lift_expr(guard_ast, ctx, block, env)
    value
  end

  defp lower_term_membership(word, {:integer_range, first, last}, ctx, block) do
    integer = create_op("ex.is_integer", [word], [MLIR.Type.i64()], ctx, block)
    scalar = create_op("ex.to_int", [word], [MLIR.Type.i64()], ctx, block)
    membership = lower_integer_range_membership(scalar, first, last, ctx, block)
    combine([integer, membership], ctx, block)
  end

  defp lower_term_membership(word, {:integer_set, integers}, ctx, block) do
    integer = create_op("ex.is_integer", [word], [MLIR.Type.i64()], ctx, block)
    scalar = create_op("ex.to_int", [word], [MLIR.Type.i64()], ctx, block)

    membership =
      integers
      |> Enum.map(&cmp(scalar, &1, "eq", ctx, block))
      |> combine_any(ctx, block)

    combine([integer, membership], ctx, block)
  end

  defp lower_term_membership(word, {:atom_set, atoms}, ctx, block) do
    atom = create_op("ex.is_atom", [word], [MLIR.Type.i64()], ctx, block)

    membership =
      atoms
      |> Enum.map(fn member ->
        tagged_atom =
          create_op(
            "ex.to_word",
            [lit(atom_word(member), ctx, block)],
            [ex_type("term", ctx)],
            ctx,
            block
          )

        create_op("ex.term_eq", [word, tagged_atom], [MLIR.Type.i64()], ctx, block)
      end)
      |> combine_any(ctx, block)

    combine([atom, membership], ctx, block)
  end

  defp lower_integer_range_membership(value, first, last, ctx, block) do
    {low, high} = if first <= last, do: {first, last}, else: {last, first}
    combine([cmp(value, low, "sge", ctx, block), cmp(value, high, "sle", ctx, block)], ctx, block)
  end

  defp lower_integer_guard_comparison(left, right, op, env, ctx, block) do
    {left, left_valid} = lower_integer_guard_expression(left, env, ctx, block)
    {right, right_valid} = lower_integer_guard_expression(right, env, ctx, block)
    comparison = cmp(left, right, cmp_predicate(op), ctx, block)
    combine([left_valid, right_valid, comparison], ctx, block)
  end

  defp lower_integer_guard_expression(integer, _env, ctx, block) when is_integer(integer),
    do: {lit(integer, ctx, block), nil}

  defp lower_integer_guard_expression({name, _, context}, env, ctx, block)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    word = env |> Map.fetch!(name) |> box_if_scalar(ctx, block)
    valid = create_op("ex.is_integer", [word], [MLIR.Type.i64()], ctx, block)
    scalar = create_op("ex.to_int", [word], [MLIR.Type.i64()], ctx, block)
    {scalar, valid}
  end

  defp lower_integer_guard_expression({op, _, [left, right]}, env, ctx, block)
       when op in [:+, :-, :*] do
    {left, left_valid} = lower_integer_guard_expression(left, env, ctx, block)
    {right, right_valid} = lower_integer_guard_expression(right, env, ctx, block)

    operation =
      case op do
        :+ -> "ex.add"
        :- -> "ex.sub"
        :* -> "ex.mul"
      end

    value = create_op(operation, [left, right], [integer_type(ctx)], ctx, block)
    {value, combine([left_valid, right_valid], ctx, block)}
  end

  defp lower_integer_guard_expression({:rem, _, [left, right]}, env, ctx, block),
    do: lower_integer_guard_rem(left, right, env, ctx, block)

  defp lower_integer_guard_expression(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :rem]}, _, [left, right]},
         env,
         ctx,
         block
       ),
       do: lower_integer_guard_rem(left, right, env, ctx, block)

  defp lower_integer_guard_expression({:byte_size, _, [{name, _, context}]}, env, ctx, block)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    lower_binary_size_guard(name, env, ctx, block)
  end

  defp lower_integer_guard_expression(
         {{:., _, [module, :byte_size]}, _, [{name, _, context}]},
         env,
         ctx,
         block
       )
       when module in [:erlang, Kernel] and is_atom(name) and
              (is_atom(context) or is_nil(context)) do
    lower_binary_size_guard(name, env, ctx, block)
  end

  defp lower_binary_size_guard(name, env, ctx, block) do
    word = env |> Map.fetch!(name) |> box_if_scalar(ctx, block)
    valid = create_op("ex.is_binary", [word], [MLIR.Type.i64()], ctx, block)
    length = create_op("ex.binary_length", [word], [MLIR.Type.i64()], ctx, block)
    {length, valid}
  end

  defp lower_integer_guard_rem(left, right, env, ctx, block) do
    {left, left_valid} = lower_integer_guard_expression(left, env, ctx, block)
    {right, right_valid} = lower_integer_guard_expression(right, env, ctx, block)
    value = create_op("ex.rem", [left, right], [integer_type(ctx)], ctx, block)
    {value, combine([left_valid, right_valid], ctx, block)}
  end

  defp integer_guard_call?({:rem, _, [_left, _right]}), do: true

  defp integer_guard_call?({{:., _, [{:__aliases__, _, [:Kernel]}, :rem]}, _, [_left, _right]}),
    do: true

  defp integer_guard_call?({:byte_size, _, [_value]}), do: true

  defp integer_guard_call?({{:., _, [module, :byte_size]}, _, [_value]})
       when module in [:erlang, Kernel],
       do: true

  defp integer_guard_call?(_ast), do: false

  defp combine_any([], ctx, block), do: lit(0, ctx, block)
  defp combine_any([single], _ctx, _block), do: single

  defp combine_any(many, ctx, block) do
    Enum.reduce(many, fn cond, acc ->
      create_op("arith.ori", [acc, cond], [MLIR.Type.i64()], ctx, block)
    end)
  end

  defp term_operand?(value) do
    value
    |> MLIR.Value.type()
    |> MLIR.to_string()
    |> then(&(&1 in ["!ex.term", "!ex.bound", "!ex.unbound"]))
  end

  defp ensure_refined_integer_operands!(values) do
    if Enum.any?(values, fn v -> MLIR.to_string(MLIR.Value.type(v)) == "!ex.term" end) do
      raise Error,
            "integer arithmetic on a term-pattern binding requires an is_integer/1 guard"
    end
  end

  defp box_if_scalar(value, ctx, block) do
    if term_operand?(value), do: value, else: box_term(value, ctx, block)
  end

  defp lit(value, ctx, block) do
    create_op(
      "ex.lit",
      [value: MLIR.Attribute.integer(MLIR.Type.i64(), value)],
      [MLIR.Type.i64()],
      ctx,
      block
    )
  end

  defp cmp(left, right, predicate, ctx, block) do
    right = if is_integer(right), do: lit(right, ctx, block), else: right

    create_op(
      "ex.cmp",
      [left, right, predicate: MLIR.Attribute.string(predicate)],
      [MLIR.Type.i64()],
      ctx,
      block
    )
  end

  defp clause_pattern({:->, _, [args, _body]}) when is_list(args) do
    case args do
      [{:when, _, [pattern, _guard]}] -> pattern
      [pattern] -> pattern
      _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
    end
  end

  defp parse_term_clause({:->, _, [args, body]}) when is_list(args) do
    {pattern, guard} =
      case args do
        [{:when, _, [pattern, guard]}] -> {pattern, guard}
        [pattern] -> {pattern, nil}
        _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
      end

    %{pattern: pattern, guard: guard, body: body}
  end

  defp term_pattern?({:=, _, [left, right]}), do: term_pattern?(left) or term_pattern?(right)
  defp term_pattern?({:%, _, _}), do: true

  defp term_pattern?(pattern) do
    match?({:%{}, _, _}, pattern) or
      pattern
      |> PatternPlan.lower_pattern()
      |> Enum.any?(&(&1.op in [:tuple, :list_exact, :list_cons, :binary, :map]))
  end

  defp parse_clause({:->, _, [args, body]}) when is_list(args) do
    {pattern, guard} =
      case args do
        [{:when, _, [pattern, guard]}] -> {pattern, guard}
        [pattern] -> {pattern, nil}
        _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
      end

    {patterns, vars} = parse_pattern(pattern)
    %{pattern: pattern, patterns: patterns, vars: vars, guard: guard, body: body}
  end

  defp parse_pattern(integer) when is_integer(integer), do: {[integer], []}

  defp parse_pattern({name, _, nil}) when is_atom(name) do
    if name == :_ do
      {[], []}
    else
      {[], [name]}
    end
  end

  defp parse_pattern(pattern) do
    raise Error, "unsupported case pattern: #{inspect(pattern)}"
  end

  defp lift_guard(guard_ast, vars, scrutinee, env, ctx, block) do
    guard_env = Enum.reduce(vars, env, fn var, acc -> Map.put(acc, var, scrutinee) end)

    if GuardSupport.compiler_supported?(guard_ast) or integer_guard_comparison?(guard_ast) do
      lift_term_guard_expr(guard_ast, guard_env, ctx, block)
    else
      {value, _env} = lift_expr(guard_ast, ctx, block, guard_env)
      value
    end
  end

  defp integer_guard_comparison?({op, _, [left, right]})
       when op in [:==, :!=, :===, :!==],
       do: integer_guard_call?(left) or integer_guard_call?(right)

  defp integer_guard_comparison?(_guard_ast), do: false

  defp add_clause_block(clause, guard, scrutinee, clause_binds, env, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    clause_env = Map.merge(env, Map.new(clause_binds))
    clause_env = Enum.reduce(clause.vars, clause_env, &Map.put(&2, &1, scrutinee))

    clause_attrs = [patterns: pattern_attr(clause.patterns)]
    clause_args = if guard, do: [guard], else: []
    create_op("ex.clause", clause_args ++ clause_attrs, [], ctx, block)

    {value, clause_env} = lift_block(block_ast(clause.body), ctx, block, clause_env)
    value = lift_value(value, ctx, block, clause_env)
    create_op("ex.yield", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    MLIR.Value.type(value)
  end

  defp pattern_attr(patterns) do
    MLIR.Attribute.dense_array(patterns, Beaver.Native.I64)
  end

  # Values crossing into a term-universe op are boxed with `ex.box`; the
  # conversion turns the box into a tagged word (and is a no-op for values
  # that already are terms).
  defp lift_operands_boxed(args, ctx, block, env) do
    Enum.map_reduce(args, env, fn arg, env ->
      {value, env} = lift_expr(arg, ctx, block, env)
      {box_term(lift_value(value, ctx, block, env), ctx, block), env}
    end)
  end

  defp box_term(value, ctx, block) do
    validate_boxed_integer_literal!(value)
    create_op("ex.box", [value], [ex_type("term", ctx)], ctx, block)
  end

  defp validate_boxed_integer_literal!(value) do
    with false <- term_operand?(value),
         {:ok, owner} <- MLIR.Value.owner(value),
         "ex.lit" <- MLIR.Operation.name(owner),
         attribute when not is_nil(attribute) <- Beaver.Walker.attributes(owner)[:value] do
      attribute
      |> MLIR.CAPI.mlirIntegerAttrGetValueInt()
      |> Beaver.Native.to_term()
      |> validate_term_integer_literal!()
    else
      _ -> :ok
    end
  end

  defp lift_map_entries(entries, ctx, block, env) do
    Enum.flat_map_reduce(entries, env, fn entry, env ->
      case entry do
        {key, value} ->
          {key_value, env} = lift_expr(key, ctx, block, env)
          {value_value, env} = lift_expr(value, ctx, block, env)

          {
            [
              box_term(lift_value(key_value, ctx, block, env), ctx, block),
              box_term(lift_value(value_value, ctx, block, env), ctx, block)
            ],
            env
          }

        other ->
          {value, env} = lift_expr(other, ctx, block, env)
          {[box_term(lift_value(value, ctx, block, env), ctx, block)], env}
      end
    end)
  end

  defp struct_constructor_entries(%Frontend.StructSchema{} = schema, provided_fields)
       when is_list(provided_fields) do
    provided =
      Enum.reduce(provided_fields, %{}, fn
        {field, value}, fields when is_atom(field) ->
          if Map.has_key?(fields, field) do
            raise Error, "duplicate struct field: #{inspect(field)}"
          end

          Map.put(fields, field, normalize_struct_field_value(value))

        field, _fields ->
          raise Error, "struct fields must use atom keys, got: #{inspect(field)}"
      end)

    declared = MapSet.new(schema.fields, &elem(&1, 0))

    case provided |> Map.keys() |> Enum.reject(&MapSet.member?(declared, &1)) do
      [] -> :ok
      unknown -> raise Error, "unknown struct fields: #{inspect(Enum.sort(unknown))}"
    end

    injected =
      [__struct__: schema.module] ++
        if(schema.kind == :exception, do: [__exception__: true], else: [])

    injected ++
      Enum.map(schema.fields, fn {field, default} ->
        {field, Map.get(provided, field, default)}
      end)
  end

  defp struct_constructor_entries(%Frontend.StructSchema{}, provided_fields) do
    raise Error, "struct fields must be a literal keyword list, got: #{inspect(provided_fields)}"
  end

  defp normalize_struct_field_value({:-, _, [value]}) when is_number(value), do: -value
  defp normalize_struct_field_value({:+, _, [value]}) when is_number(value), do: value
  defp normalize_struct_field_value(value), do: value

  defp create_term_op(op_name, args, ctx, block) do
    create_op(
      op_name,
      args ++ [operandSegmentSizes: segment_sizes([length(args)])],
      [ex_type("term", ctx)],
      ctx,
      block
    )
  end

  defp insert_return(nil, ctx, block, _env) do
    create_op("ex.return", [operandSegmentSizes: segment_sizes([0])], [], ctx, block)
    :ok
  end

  defp insert_return(value, ctx, block, env) do
    value = lift_value(value, ctx, block, env)
    create_op("ex.return", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    :ok
  end

  defp create_op(op_name, arguments, result_types, ctx, block) do
    operation =
      %Beaver.SSA{
        op: op_name,
        ip: block,
        ctx: ctx,
        arguments: arguments,
        results: result_types,
        loc: MLIR.Location.unknown()
      }
      |> MLIR.Operation.create()

    case result_types do
      [] -> operation
      [_] -> operation |> MLIR.Operation.results() |> Enum.to_list() |> hd()
      _ -> operation |> MLIR.Operation.results() |> Enum.to_list()
    end
  end

  defp param_name({name, _, nil}) when is_atom(name), do: name
  defp param_name(pattern), do: raise(Error, "unsupported parameter pattern: #{inspect(pattern)}")

  defp function_arg_modes(name, arity, module_env) do
    module_env
    |> Map.fetch!(@arg_modes_key)
    |> Map.get({name, arity}, List.duplicate(:scalar, arity))
  end

  defp term_case_opts(name, arity, module_env) do
    if name |> function_arg_modes(arity, module_env) |> List.first() == :term,
      do: [term_case?: true],
      else: []
  end

  defp inbound_argument(value, :term, ctx, block),
    do: create_op("ex.to_word", [value], [ex_type("term", ctx)], ctx, block)

  defp inbound_argument(value, :scalar, _ctx, _block), do: value

  defp adapt_call_arguments(name, values, env, ctx, block) do
    modes =
      env
      |> Map.fetch!(@arg_modes_key)
      |> Map.get({name, length(values)}, List.duplicate(:scalar, length(values)))

    Enum.zip_with(values, modes, fn
      value, :term -> value |> box_if_scalar(ctx, block) |> unbox(ctx, block)
      value, :scalar -> value
    end)
  end

  defp integer_type(ctx), do: MLIR.Type.integer(64, ctx: ctx)

  defp ex_type(name, ctx) do
    Beaver.Slang.create_constrained_element(:type, "ex", name, [], ctx: ctx)
    |> Beaver.Deferred.resolve(ctx)
  end

  defp segment_sizes(sizes) do
    MLIR.Attribute.dense_array(sizes, Beaver.Native.I32)
  end

  # ex.call has eight optional argument slots (the closure ABI adds four);
  # encode which are filled.
  defp arg_segment_sizes(count) do
    unless count <= 8 do
      raise Error, "calls with more than 8 arguments are unsupported: #{count}"
    end

    List.duplicate(1, count) ++ List.duplicate(0, 8 - count)
  end
end
