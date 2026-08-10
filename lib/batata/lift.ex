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
  alias Batata.Transform.PatternPlan
  alias Beaver.MLIR
  alias Beaver.MLIR.Dialect.Ex
  alias Beaver.Walker

  defmodule Error do
    @moduledoc "Raised when the frontend encounters an unsupported AST form."
    defexception [:message]
  end

  @doc """
  Builds a `builtin.module` of `ex.func` operations for the snapshot.

  Returns a `Beaver.Deferred`; materialize it with `Beaver.Deferred.create/2`
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

      {definitions, entry_name} =
        if driver_needed?(mod.definitions, budget) do
          rename_entry(mod.definitions)
        else
          {mod.definitions, nil}
        end

      definitions =
        definitions
        |> recognize_enum_calls()
        |> extract_all_fns()
        |> then(&append_dispatch(&1))

      groups = Enum.group_by(definitions, &{&1.name, &1.arity})
      enforce_resumable_plan(groups, budget)

      Enum.each(groups, fn {_key, definitions} ->
        lift_definitions(definitions, ctx, body, budget)
      end)

      if entry_name != nil and driver_needed?(definitions, budget) do
        lift_driver(entry_name, ctx, body, budget, dispatch_exists?(definitions))
      end

      module
    end)
  end

  # The entry function (`main` for the JIT path, `batata_main` for the AOT
  # path) is renamed to `__batata_entry` so the generated scheduler driver
  # can take its name and re-invoke it to resume a preempted process. Returns
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
  defp enforce_resumable_plan(groups, budget) do
    if budget != nil do
      Enum.each(groups, fn {_key, definitions} ->
        [%Frontend.Definition{name: name, arity: arity} | _] = definitions
        clauses = Enum.flat_map(definitions, & &1.clauses)

        scanner? =
          if length(definitions) > 1 do
            case arity do
              1 -> match?({:ok, _}, detect_scanner(name, clauses))
              arity when arity >= 2 -> match?({:ok, _}, detect_accumulator_scanner(name, clauses))
              _ -> false
            end
          else
            false
          end

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
      end)
    end
  end

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

  # The scheduler driver is generated when a reduction budget is set (the
  # entry may be preempted and must be resumed) or when the source spawns
  # processes (they must be executed to completion).
  defp driver_needed?(definitions, budget) do
    budget != nil or Enum.any?(definitions, &definition_spawns?/1)
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

  defp recognize_enum_node(node, state) do
    case node do
      {{:., _, [{:__aliases__, _, alias_parts}, :map]}, _, [enumerable, fn_ast]} = node ->
        if enum_alias?(alias_parts) or stream_alias?(alias_parts) do
          case map_pattern(fn_ast) do
            {:ok, {:mapper, body_ast, item_name}} ->
              {marker, state} = extract_mapper(body_ast, item_name, enumerable, state)
              {marker, state}

            {:ok, pattern} ->
              {{:__enum_call__, [], [:map, pattern, enumerable]}, state}

            :error ->
              {node, state}
          end
        else
          {node, state}
        end

      {{:., _, [{:__aliases__, _, alias_parts}, :filter]}, _, [enumerable, fn_ast]} = node ->
        if stream_alias?(alias_parts) do
          case predicate_pattern(fn_ast) do
            {:ok, body_ast, item_name} ->
              {marker, state} = extract_predicate(body_ast, item_name, enumerable, state)
              {marker, state}

            :error ->
              {node, state}
          end
        else
          {node, state}
        end

      {{:., _, [{:__aliases__, _, alias_parts}, :reduce]}, _, [enumerable, acc, fn_ast]} = node ->
        if enum_alias?(alias_parts) do
          case reduce_pattern(fn_ast) do
            {:ok, {:combination, body_ast, item_name, acc_name}} ->
              {marker, state} =
                extract_combination_reducer(body_ast, item_name, acc_name, enumerable, acc, state)

              {marker, state}

            {:ok, pattern} ->
              {{:__enum_call__, [], [:reduce, pattern, enumerable, acc]}, state}

            :error ->
              {node, state}
          end
        else
          {node, state}
        end

      node ->
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
    end
  end

  defp map_pattern(_), do: :error

  defp reduce_pattern({:fn, _, [{:->, _, [[item, acc_var], body]}]}) do
    cond do
      sum_pattern?(body, item, acc_var) ->
        {:ok, :sum}

      product_pattern?(body, item, acc_var) ->
        {:ok, :product}

      subtract_pattern?(body, item, acc_var) ->
        {:ok, subtract_direction(body, item, acc_var)}

      div_rem_pattern?(body, item, acc_var) ->
        {:ok, div_rem_direction(body, item, acc_var)}

      capture_sum_pattern?(body, item, acc_var) ->
        {:ok, capture} = capture_addend(body, item, acc_var)
        {:ok, {:capture_sum, capture}}

      capture_product_pattern?(body, item, acc_var) ->
        capture = capture_product_addend(body, item)
        {:ok, {:capture_product, capture}}

      map_values_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_values_sum}

      map_keys_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_keys_sum}

      map_entries_sum_pattern?(body, item, acc_var) ->
        {:ok, :map_entries_sum}

      same_var?(body, acc_var) ->
        {:ok, :return_acc}

      combination_pattern?(body, item, acc_var) ->
        {:ok, {:combination, body, tree_var_name(item), tree_var_name(acc_var)}}

      true ->
        :error
    end
  end

  defp reduce_pattern(_), do: :error

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
    with {:ok, key_var, value_var} <- map_entry_vars(item) do
      body
      |> collect_add_vars()
      |> MapSet.new()
      |> MapSet.equal?(
        MapSet.new([tree_var_name(key_var), tree_var_name(value_var), tree_var_name(acc_var)])
      )
    else
      :error -> false
    end
  end

  defp map_entry_add_pattern?({:+, _, [left, right]}, item, acc_var, selector) do
    with {:ok, entry_var} <- map_entry_var(item, selector) do
      (same_var?(left, entry_var) and same_var?(right, acc_var)) or
        (same_var?(left, acc_var) and same_var?(right, entry_var))
    else
      :error -> false
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
         budget
       ) do
    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    unless length(clauses) == 1 do
      raise Error, "multiple clauses are unsupported in the scalar slice: #{name}/#{arity}"
    end

    [%Frontend.Clause{patterns: patterns, body_ast: body_ast}] = clauses

    region = MLIR.CAPI.mlirRegionCreate()
    arg_types = List.duplicate(integer_type(ctx), length(patterns))
    arg_locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), length(patterns))
    block = MLIR.Block.create(arg_types, arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    env =
      block
      |> Walker.arguments()
      |> Enum.to_list()
      |> Enum.zip(patterns)
      |> Enum.reduce(%{}, fn {value, pattern}, env ->
        Map.put(env, param_name(pattern), value)
      end)
      |> Map.put(:__budget__, budget)

    # The entry function starts a fresh actor: reset the mailbox and the
    # reduction clock so each program run observes a clean process (budget 0
    # keeps the tick a no-op when no explicit budget is set) (#35). Under a
    # reduction budget the mailbox is cleared only on the first slice: a
    # resumed slice must keep messages that arrived while it was suspended.
    if name in [:__batata_entry, :main] and uses_mailbox?(body_ast) do
      if budget == nil do
        create_op("ex.mailbox_clear", [], [ex_type("dyn", ctx)], ctx, block)
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
        create_op("ex.mailbox_clear", [], [ex_type("dyn", ctx)], ctx, fresh_block)
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

    if name in [:__batata_entry, :main] do
      create_op("ex.clock_init", [lit(budget || 0, ctx, block)], [integer_type(ctx)], ctx, block)
    end

    {return_value, env} = lift_block(List.wrap(body_ast), ctx, block, env)
    insert_return(return_value, ctx, block, env)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

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

  defp lift_definitions([definition], ctx, ip, budget) do
    lift_definition(definition, ctx, ip, budget)
  end

  # Multiple `def` forms with the same name/arity become one ex.func whose
  # body dispatches on the argument with ex.case, matching each clause's
  # pattern (the cursor-loop foundation for recursive scanners). M2 requires
  # a single argument and a final catch-all clause.
  defp lift_definitions(definitions, ctx, ip, budget) do
    %Frontend.Definition{kind: kind, name: name, arity: arity} = hd(definitions)

    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    clauses = Enum.flat_map(definitions, & &1.clauses)

    cond do
      arity == 1 ->
        case detect_scanner(name, clauses) do
          {:ok, scanner} -> lift_scanner_loop(name, scanner, ctx, ip, budget)
          :skip -> lift_multi_clause_dispatch(name, clauses, ctx, ip)
        end

      arity >= 2 ->
        case detect_accumulator_scanner(name, clauses) do
          {:ok, scanner} -> lift_reduce_loop(name, scanner, ctx, ip, budget)
          :skip -> lift_multi_arg_dispatch(name, arity, clauses, ctx, ip)
        end

      true ->
        raise Error, "unsupported function arity: #{name}/#{arity}"
    end
  end

  defp lift_multi_clause_dispatch(name, clauses, ctx, ip) do
    region = MLIR.CAPI.mlirRegionCreate()

    # The argument is a scalar word (like single-clause functions); the term
    # path re-types it with ex.to_word when term reads are involved.
    arg_locs = [MLIR.Location.unknown(ctx: ctx)]
    block = MLIR.Block.create([integer_type(ctx)], arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg] = block |> Walker.arguments() |> Enum.to_list()

    clause_asts =
      Enum.map(clauses, fn %Frontend.Clause{patterns: [pattern], body_ast: body_ast} ->
        {:->, [], [[pattern], body_ast]}
      end)

    return_value =
      lift_case(clause_asts, arg, %{}, ctx, block, relax_types: true, box_scrutinee: false)

    insert_return(return_value, ctx, block, %{})

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  # Multi-argument multi-clause functions (e.g. `reduce(binary, acc)`): the
  # first argument dispatches with `ex.case`; the trailing arguments must be
  # bound as variables and are threaded through the clause environments.
  defp lift_multi_arg_dispatch(name, arity, clauses, ctx, ip) do
    tail_names = validate_multi_arg_clauses!(arity, clauses)

    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)
    i64 = integer_type(ctx)
    locs = List.duplicate(loc, arity)

    block = MLIR.Block.create(List.duplicate(i64, arity), locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg1 | tail_args] = block |> Walker.arguments() |> Enum.to_list()
    tail_env = Map.new(Enum.zip(tail_names, tail_args))

    clause_asts =
      Enum.map(clauses, fn %Frontend.Clause{patterns: [first | _], body_ast: body_ast} ->
        {:->, [], [[first], body_ast]}
      end)

    return_value =
      lift_case(clause_asts, arg1, tail_env, ctx, block, relax_types: true, box_scrutinee: false)

    insert_return(return_value, ctx, block, tail_env)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp validate_multi_arg_clauses!(arity, clauses) do
    tail_names =
      clauses
      |> Enum.map(fn %Frontend.Clause{patterns: patterns} ->
        unless length(patterns) == arity do
          raise Error, "clause arity mismatch for a multi-clause function"
        end

        {_first, tails} = Enum.split(patterns, 1)

        Enum.map(tails, fn
          {name, _, nil} when is_atom(name) and name != :_ ->
            name

          other ->
            raise Error, "multi-clause trailing arguments must be variables: #{inspect(other)}"
        end)
      end)
      |> Enum.uniq()

    case tail_names do
      [names] ->
        names

      _ ->
        raise Error,
              "multi-clause multi-argument functions must use the same trailing argument names"
    end
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
         %Frontend.Clause{patterns: [p1, acc_pat], body_ast: body_ast},
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

  defp scanner_clause(%Frontend.Clause{patterns: [pattern], body_ast: body_ast}, name) do
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

  defp binary_segments({:<<>>, _, segments}) do
    {bytes, rest} =
      Enum.split_while(segments, &(not match?({:"::", _, [_, {:binary, _, nil}]}, &1)))

    if Enum.all?(bytes, &byte_segment?/1) do
      case rest do
        [] ->
          {:ok, length(bytes), nil}

        [{:"::", _, [rest_pat, {:binary, _, nil}]}] ->
          case rest_pat do
            {name, _, nil} when is_atom(name) and name != :_ -> {:ok, length(bytes), rest_pat}
            _ -> :skip
          end

        _ ->
          :skip
      end
    else
      :skip
    end
  end

  defp binary_segments(_), do: :skip

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

  defp lift_scanner_loop(name, %{base: base, delta: delta, head_width: width}, ctx, ip, budget) do
    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)
    i64 = integer_type(ctx)

    block = MLIR.Block.create([i64], [loc])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg] = block |> Walker.arguments() |> Enum.to_list()

    base_val = lit(base, ctx, block)
    acc_result = emit_cursor_while(block, arg, base_val, width, delta, ctx, budget)
    create_op("ex.return", [acc_result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp lift_reduce_loop(name, %{delta: delta, head_width: width}, ctx, ip, budget) do
    region = MLIR.CAPI.mlirRegionCreate()
    loc = MLIR.Location.unknown(ctx: ctx)

    block = MLIR.Block.create([integer_type(ctx), integer_type(ctx)], [loc, loc])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg, acc0] = block |> Walker.arguments() |> Enum.to_list()

    acc_result = emit_cursor_while(block, arg, acc0, width, delta, ctx, budget)
    create_op("ex.return", [acc_result, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
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
  defp lift_driver(entry_name, ctx, ip, _budget, has_dispatch) do
    i64 = integer_type(ctx)
    dyn = ex_type("dyn", ctx)
    i1 = MLIR.Type.i1()

    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    # Each program run starts with a fresh actor table.
    create_op("ex.process_table_reset", [], [i64], ctx, block)

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
    create_op("ex.return", [final, operandSegmentSizes: segment_sizes([1])], [], ctx, block)

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

  # Calls the compiled entry (`__batata_entry`) with no arguments.
  defp call_entry(ctx, block) do
    create_op(
      "ex.call",
      [
        callee: MLIR.Attribute.string("__batata_entry"),
        arity: MLIR.Attribute.integer(MLIR.Type.i64(), 0),
        operandSegmentSizes: segment_sizes(arg_segment_sizes(0))
      ],
      [ex_type("dyn", ctx)],
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
  defp emit_cursor_while(block, arg, acc, width, delta, ctx, budget) do
    i64 = integer_type(ctx)

    locs = [
      MLIR.Location.unknown(ctx: ctx),
      MLIR.Location.unknown(ctx: ctx),
      MLIR.Location.unknown(ctx: ctx)
    ]

    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_arg, b_acc, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
    word = create_op("ex.to_word", [b_arg], [ex_type("dyn", ctx)], ctx, before_block)
    len = create_op("ex.binary_length", [word], [i64], ctx, before_block)

    next_cursor =
      create_op("ex.add", [b_cursor, lit(width, ctx, before_block)], [i64], ctx, before_block)

    cond = cmp(len, next_cursor, "sge", ctx, before_block)
    cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)

    budget_cond =
      inject_reduction_tick(before_block, ctx, cond_i1, budget, b_arg, b_acc, b_cursor, false)

    create_op("scf.condition", [budget_cond, b_arg, b_acc, b_cursor], [], ctx, before_block)

    [a_arg, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
    acc_next = create_op("ex.add", [a_acc, lit(delta, ctx, after_block)], [i64], ctx, after_block)

    cursor_next =
      create_op("ex.add", [a_cursor, lit(width, ctx, after_block)], [i64], ctx, after_block)

    create_op("scf.yield", [a_arg, acc_next, cursor_next], [], ctx, after_block)

    {state_arg, state_acc, state_cursor} =
      resumable_loop_state(block, ctx, budget, fn b ->
        {arg, acc, lit(0, ctx, b)}
      end)

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
  end

  # `Enum.reduce/3` with a `fn item, acc -> item + acc end` reducer compiles
  # to a cursor loop over the list: carries (list, acc, cursor), reads each
  # element via `ex.list_get`, untags it, and accumulates.
  defp lift_enum_sum_loop(list_word, acc0, ctx, block, budget) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.add", :acc_first}, ctx, block, budget)
  end

  # #35 slice 2/3: charge one reduction per loop iteration (the scf.while
  # before region runs once per iteration). Without a budget the tick is a
  # no-op. With a budget, an exhausted budget saves the cursor-loop
  # continuation (arg, acc, cursor) to the runtime and records a yield; the
  # condition becomes false so the loop exits and the entry returns control
  # to the scheduler driver, which resumes the saved state later (#35 slice 5).
  defp inject_reduction_tick(before_block, ctx, cond_i1, budget, arg, acc, cursor, receive?) do
    i64 = integer_type(ctx)

    ticked =
      create_op("ex.reduction_tick", [lit(1, ctx, before_block)], [i64], ctx, before_block)

    if budget == nil do
      not_exhausted =
        create_op(
          "ex.cmp",
          [ticked, lit(0, ctx, before_block), predicate: MLIR.Attribute.string("eq")],
          [i64],
          ctx,
          before_block
        )

      not_exhausted_i1 =
        create_op("arith.trunci", [not_exhausted], [MLIR.Type.i1()], ctx, before_block)

      create_op("arith.andi", [cond_i1, not_exhausted_i1], [MLIR.Type.i1()], ctx, before_block)
    else
      # Budgeted: exhausted -> cont_save + yield_mark; condition becomes false
      # so the loop exits (a real preemptive yield, not an immediate resume).
      exhausted =
        create_op(
          "ex.cmp",
          [ticked, lit(0, ctx, before_block), predicate: MLIR.Attribute.string("ne")],
          [i64],
          ctx,
          before_block
        )

      exhausted_i1 =
        create_op("arith.trunci", [exhausted], [MLIR.Type.i1()], ctx, before_block)

      if_region = MLIR.CAPI.mlirRegionCreate()
      if_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(if_region, if_block)

      else_region = MLIR.CAPI.mlirRegionCreate()
      else_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(else_region, else_block)

      # Selective-receive scans save a receive-type continuation so a message
      # arrival invalidates it (epoch wiring); cursor loops save a loop-type
      # continuation that message arrival must not affect.
      save_op = if receive?, do: "ex.receive_cont_save", else: "ex.cont_save"
      create_op(save_op, [arg, acc, cursor], [i64], ctx, if_block)
      create_op("ex.yield_mark", [], [i64], ctx, if_block)

      false_i1 =
        create_op("arith.trunci", [lit(0, ctx, if_block)], [MLIR.Type.i1()], ctx, if_block)

      create_op("scf.yield", [false_i1], [], ctx, if_block)
      create_op("scf.yield", [cond_i1], [], ctx, else_block)

      if_op =
        %Beaver.SSA{
          op: "scf.if",
          ip: before_block,
          ctx: ctx,
          arguments: [exhausted_i1],
          results: [MLIR.Type.i1()],
          loc: MLIR.Location.unknown(),
          filler: fn -> [if_region, else_region] end
        }
        |> MLIR.Operation.create()

      if_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
    end
  end

  # Computes the initial (arg, acc, cursor) state of a cursor loop. Without a
  # budget the loop runs the fresh init inline (single invocation). With a
  # budget the loop is resumable: each invocation starts by resetting the
  # process's reduction clock (a new slice) and checks for a saved
  # continuation — when one is pending at the current epoch, the state is
  # restored from the runtime so the loop resumes where it yielded; otherwise
  # the fresh init runs.
  defp resumable_loop_state(block, ctx, budget, fresh_init) do
    if budget == nil do
      fresh_init.(block)
    else
      i64 = integer_type(ctx)
      create_op("ex.clock_init", [lit(budget, ctx, block)], [i64], ctx, block)

      # Resume on any saved continuation (valid or stale): the cursor-loop
      # state is positionally valid even after a message arrival invalidates
      # the token, and a selective-receive scan observes new messages through
      # the live mailbox-length check. Epoch invalidation is detected by
      # `ex.term.cont_pending` (the driver's parking check and runtime tests);
      # restarting the loop here would re-run the entry's pre-loop side
      # effects.
      active = create_op("ex.cont_active", [], [i64], ctx, block)

      active_i1 =
        create_op("arith.trunci", [active], [MLIR.Type.i1()], ctx, block)

      resume_region = MLIR.CAPI.mlirRegionCreate()
      resume_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(resume_region, resume_block)
      arg_v = create_op("ex.cont_load_arg", [], [i64], ctx, resume_block)
      acc_v = create_op("ex.cont_load_acc", [], [i64], ctx, resume_block)
      cursor_v = create_op("ex.cont_load_cursor", [], [i64], ctx, resume_block)
      # The continuation is consumed by the resume: a completed loop must not
      # read as still pending (the driver parks a process only when the entry
      # returns with no pending continuation).
      create_op("ex.cont_clear", [], [i64], ctx, resume_block)
      create_op("scf.yield", [arg_v, acc_v, cursor_v], [], ctx, resume_block)

      fresh_region = MLIR.CAPI.mlirRegionCreate()
      fresh_block = MLIR.Block.create([], [])
      MLIR.CAPI.mlirRegionAppendOwnedBlock(fresh_region, fresh_block)
      {arg_f, acc_f, cursor_f} = fresh_init.(fresh_block)
      create_op("scf.yield", [arg_f, acc_f, cursor_f], [], ctx, fresh_block)

      if_op =
        %Beaver.SSA{
          op: "scf.if",
          ip: block,
          ctx: ctx,
          arguments: [active_i1],
          results: [i64, i64, i64],
          loc: MLIR.Location.unknown(),
          filler: fn -> [resume_region, fresh_region] end
        }
        |> MLIR.Operation.create()

      [arg, acc, cursor] = if_op |> MLIR.Operation.results() |> Enum.to_list()
      {arg, acc, cursor}
    end
  end

  defp lift_enum_product_loop(list_word, acc0, ctx, block, budget) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.mul", :acc_first}, ctx, block, budget)
  end

  defp lift_enum_subtract_loop(list_word, acc0, order, ctx, block, budget) do
    lift_enum_cursor_loop(list_word, acc0, {"ex.sub", order}, ctx, block, budget)
  end

  defp lift_enum_cursor_loop(list_word, acc0, {accumulate_op, order}, ctx, block, budget) do
    i64 = integer_type(ctx)
    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)

    {state_list, state_acc, state_cursor} =
      resumable_loop_state(block, ctx, budget, fn b ->
        list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
        {list_i64, acc0, lit(0, ctx, b)}
      end)

    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_list, b_acc, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
    b_word = create_op("ex.to_word", [b_list], [ex_type("dyn", ctx)], ctx, before_block)
    len = create_op("ex.list_length", [b_word], [i64], ctx, before_block)
    cond = cmp(b_cursor, len, "slt", ctx, before_block)
    cond_i1 = create_op("arith.trunci", [cond], [MLIR.Type.i1()], ctx, before_block)

    budget_cond =
      inject_reduction_tick(before_block, ctx, cond_i1, budget, b_list, b_acc, b_cursor, false)

    create_op("scf.condition", [budget_cond, b_list, b_acc, b_cursor], [], ctx, before_block)

    [a_list, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
    a_word = create_op("ex.to_word", [a_list], [ex_type("dyn", ctx)], ctx, after_block)

    item =
      create_op("ex.list_get", [a_word, a_cursor], [ex_type("dyn", ctx)], ctx, after_block)

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
  defp lift_enum_const_map(list_word, value, ctx, block, budget) do
    lift_enum_map_loop(
      list_word,
      ctx,
      block,
      fn _item, b -> lit(value, ctx, b) end,
      budget
    )
  end

  # `Enum.map/2` with a capture-add mapper (`fn x -> x + c end`) compiles to
  # the same descending loop, adding the captured scalar to each element.
  defp lift_enum_capture_map(list_word, capture_i64, ctx, block, budget) do
    lift_enum_map_loop(
      list_word,
      ctx,
      block,
      fn item, b ->
        create_op("ex.add", [item, capture_i64], [integer_type(ctx)], ctx, b)
      end,
      budget
    )
  end

  defp lift_enum_map_loop(list_word, ctx, block, mapper_fun, budget) do
    i64 = integer_type(ctx)

    {state_list, state_acc, state_cursor} =
      resumable_loop_state(block, ctx, budget, fn b ->
        list_i64 = create_op("ex.unbox", [list_word], [i64], ctx, b)
        len = create_op("ex.list_length", [list_word], [i64], ctx, b)
        cursor0 = create_op("ex.sub", [len, lit(1, ctx, b)], [i64], ctx, b)
        nil_dyn = create_term_op("ex.list", [], ctx, b)
        nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, b)
        {list_i64, nil_i64, cursor0}
      end)

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

    budget_cond =
      inject_reduction_tick(before_block, ctx, cond_i1, budget, b_list, b_acc, b_cursor, false)

    create_op("scf.condition", [budget_cond, b_list, b_acc, b_cursor], [], ctx, before_block)

    [a_list, a_acc, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
    a_word = create_op("ex.to_word", [a_list], [ex_type("dyn", ctx)], ctx, after_block)

    item =
      create_op("ex.list_get", [a_word, a_cursor], [ex_type("dyn", ctx)], ctx, after_block)

    item_i64 = create_op("ex.to_int", [item], [i64], ctx, after_block)
    mapped = mapper_fun.(item_i64, after_block)
    mapped_term = box_term(mapped, ctx, after_block)
    acc_dyn = create_op("ex.to_word", [a_acc], [ex_type("dyn", ctx)], ctx, after_block)

    acc_next_dyn =
      create_op("ex.list_cons", [mapped_term, acc_dyn], [ex_type("dyn", ctx)], ctx, after_block)

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
    create_op("ex.to_word", [acc_i64], [ex_type("dyn", ctx)], ctx, block)
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

    case Map.pop(env, :__yield_gate__) do
      {nil, env} ->
        if rest == [] do
          {value, env}
        else
          lift_block_gated(rest, ctx, block, env)
        end

      {{pending_i1, loop_result}, env} ->
        if rest == [] do
          # The loop is the function tail: no post-loop body to gate.
          {value, env}
        else
          gate_value =
            build_scf_if(
              pending_i1,
              ctx,
              block,
              [integer_type(ctx)],
              fn _b ->
                [loop_result]
              end,
              fn b ->
                {rest_value, _rest_env} = lift_block_gated(rest, ctx, b, env)
                [rest_value]
              end
            )
            |> hd()

          {gate_value, env}
        end
    end
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

  defp lift_expr(elements, ctx, block, env) when is_list(elements) do
    {values, env} = lift_operands_boxed(elements, ctx, block, env)
    {create_term_op("ex.list", values, ctx, block), env}
  end

  defp lift_expr({:%{}, _, entries}, ctx, block, env) do
    {values, env} = lift_map_entries(entries, ctx, block, env)
    {create_term_op("ex.map", values, ctx, block), env}
  end

  defp lift_expr({:<<>>, _, segments}, ctx, block, env) do
    {values, env} = lift_operands_boxed(segments, ctx, block, env)
    {create_term_op("ex.binary", values, ctx, block), env}
  end

  defp lift_expr({name, _, [arg]}, ctx, block, env)
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer] do
    {value, env} = lift_expr(arg, ctx, block, env)
    {create_op("ex.#{name}", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block), env}
  end

  defp lift_expr({op, _, [left, right]}, ctx, block, env)
       when op in [:==, :!=, :<, :<=, :>, :>=] do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    if term_operand?(left_value) or term_operand?(right_value) do
      unless op in [:==, :!=] do
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

      if op == :== do
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
    op = if name == :div, do: "ex.div", else: "ex.rem"
    {create_op(op, [left_value, right_value], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_expr({:case, _, [scrutinee_ast, [do: clauses]]}, ctx, block, env) do
    {scrutinee, env} = lift_expr(scrutinee_ast, ctx, block, env)
    {lift_case(clauses, scrutinee, env, ctx, block), env}
  end

  defp lift_expr({:__block__, _, expressions}, ctx, block, env) do
    lift_block(expressions, ctx, block, env)
  end

  defp lift_expr({:=, _, [{var, _, nil}, rhs]}, ctx, block, env) when is_atom(var) do
    {value, env} = lift_expr(rhs, ctx, block, env)
    {value, Map.put(env, var, value)}
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
          {lift_enum_const_map(enumerable_word, value, ctx, block, env[:__budget__]), env}

        {:add_capture, capture_ast} ->
          {capture, env} = lift_expr(capture_ast, ctx, block, env)
          capture_i64 = enum_capture_i64(capture, ctx, block)

          {lift_enum_capture_map(enumerable_word, capture_i64, ctx, block, env[:__budget__]), env}

        {:mapper, mapper_name} ->
          addr =
            create_op(
              "ex.func_addr",
              [sym_name: MLIR.Attribute.string(to_string(mapper_name))],
              [MLIR.Type.function([integer_type(ctx)], [integer_type(ctx)])],
              ctx,
              block
            )

          {
            create_op(
              "ex.enumerable_map_fun",
              [enumerable_word, addr],
              [ex_type("dyn", ctx)],
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
        [sym_name: MLIR.Attribute.string(to_string(predicate_name))],
        [MLIR.Type.function([integer_type(ctx)], [integer_type(ctx)])],
        ctx,
        block
      )

    {
      create_op(
        "ex.stream_filter",
        [enumerable_word, addr],
        [ex_type("dyn", ctx)],
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
                callee: MLIR.Attribute.string(to_string(name)),
                arity: MLIR.Attribute.integer(MLIR.Type.i64(), 8),
                operandSegmentSizes: segment_sizes(arg_segment_sizes(8))
              ],
            [ex_type("dyn", ctx)],
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

        closure_word = create_op("ex.to_word", [closure], [ex_type("dyn", ctx)], ctx, block)

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
            [ex_type("dyn", ctx)],
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
    {create_op("ex.self", [], [ex_type("dyn", ctx)], ctx, block), env}
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
        [ex_type("dyn", ctx)],
        ctx,
        block
      )

    msg_word = box_term(lift_value(msg_value, ctx, block, env), ctx, block)

    {
      create_op("ex.send", [pid_word, msg_word], [ex_type("dyn", ctx)], ctx, block),
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
        msg = create_op("ex.receive", [], [ex_type("dyn", ctx)], ctx, block)
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
    {create_op("ex.throw", [value], [ex_type("dyn", ctx)], ctx, block), env}
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

    thrown = create_op("ex.catch_value", [], [ex_type("dyn", ctx)], ctx, catch_block)

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
        results: [ex_type("dyn", ctx)],
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

      {
        create_op(
          "ex.call",
          arg_values ++
            [
              callee: MLIR.Attribute.string(to_string(name)),
              arity: MLIR.Attribute.integer(MLIR.Type.i64(), length(args)),
              operandSegmentSizes: segment_sizes(arg_segment_sizes(length(args)))
            ],
          [ex_type("dyn", ctx)],
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

  # Selective receive: a cursor loop over the mailbox that tries each message
  # against the clauses and removes the first match. The loop state is
  # (found, result, cursor); with a reduction budget the scan is preemptible
  # and saves a receive-type continuation, which a message arrival
  # invalidates — the scan then restarts and observes the new message.
  defp lift_selective_receive(clauses, ctx, block, env, after_clause) do
    i64 = integer_type(ctx)
    i1 = MLIR.Type.i1()
    budget = env[:__budget__]
    parsed = Enum.map(clauses, &parse_term_clause/1)

    {state_found, state_result, state_cursor} =
      resumable_loop_state(block, ctx, budget, fn b ->
        {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
      end)

    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)
    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_found, b_result, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()
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
      if after_clause == nil do
        create_op("arith.andi", [not_found_i1, more_i1], [i1], ctx, before_block)
      else
        # With `after`, a completed scan round (cursor >= len) is handled in
        # the body: the wait loop re-scans or times out.
        not_found_i1
      end

    budget_cond =
      inject_reduction_tick(before_block, ctx, cond_i1, budget, b_found, b_result, b_cursor, true)

    create_op("scf.condition", [budget_cond, b_found, b_result, b_cursor], [], ctx, before_block)

    [a_found, a_result, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
    len = create_op("ex.mailbox_len", [], [i64], ctx, after_block)

    more_i1 =
      create_op(
        "arith.trunci",
        [cmp(a_cursor, len, "slt", ctx, after_block)],
        [i1],
        ctx,
        after_block
      )

    if after_clause == nil do
      msg = create_op("ex.mailbox_peek", [a_cursor], [ex_type("dyn", ctx)], ctx, after_block)

      {n_found, n_result, n_cursor} =
        receive_match_try(parsed, msg, a_cursor, env, ctx, after_block, i64)

      create_op("scf.yield", [n_found, n_result, n_cursor], [], ctx, after_block)
    else
      [n_found, n_result, n_cursor] =
        build_scf_if(
          more_i1,
          ctx,
          after_block,
          [i64, i64, i64],
          fn b ->
            msg = create_op("ex.mailbox_peek", [a_cursor], [ex_type("dyn", ctx)], ctx, b)
            {f, r, c} = receive_match_try(parsed, msg, a_cursor, env, ctx, b, i64)
            [f, r, c]
          end,
          fn b ->
            {f, r, c} =
              receive_timeout_check(after_clause, a_found, a_result, a_cursor, env, ctx, b)

            [f, r, c]
          end
        )

      create_op("scf.yield", [n_found, n_result, n_cursor], [], ctx, after_block)
    end

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments: [state_found, state_result, state_cursor],
        results: [i64, i64, i64],
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    [found, result, _cursor] = while_op |> MLIR.Operation.results() |> Enum.to_list()
    found_i1 = create_op("arith.trunci", [cmp(found, 0, "ne", ctx, block)], [i1], ctx, block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("dyn", ctx)], ctx, block)
    nil_i64 = create_op("ex.unbox", [nil_dyn], [i64], ctx, block)

    final =
      build_scf_if(found_i1, ctx, block, [i64], fn _b -> [result] end, fn _b -> [nil_i64] end)
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
    {match_cond, binds} = build_match(pattern, msg, ctx, block, guard == nil)

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

    {state_found, state_result, state_cursor} =
      resumable_loop_state(block, ctx, budget, fn b ->
        {lit(0, ctx, b), lit(0, ctx, b), lit(0, ctx, b)}
      end)

    locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), 3)
    before = MLIR.CAPI.mlirRegionCreate()
    before_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(before, before_block)

    after_region = MLIR.CAPI.mlirRegionCreate()
    after_block = MLIR.Block.create([i64, i64, i64], locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(after_region, after_block)

    [b_found, b_result, b_cursor] = before_block |> Walker.arguments() |> Enum.to_list()

    not_found_i1 =
      create_op(
        "arith.trunci",
        [cmp(b_found, 0, "eq", ctx, before_block)],
        [i1],
        ctx,
        before_block
      )

    budget_cond =
      inject_reduction_tick(
        before_block,
        ctx,
        not_found_i1,
        budget,
        b_found,
        b_result,
        b_cursor,
        true
      )

    create_op("scf.condition", [budget_cond, b_found, b_result, b_cursor], [], ctx, before_block)

    [a_found, a_result, a_cursor] = after_block |> Walker.arguments() |> Enum.to_list()
    msg = create_op("ex.receive", [], [ex_type("dyn", ctx)], ctx, after_block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("dyn", ctx)], ctx, after_block)
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

    create_op("scf.yield", [n_found, n_result, n_cursor], [], ctx, after_block)

    while_op =
      %Beaver.SSA{
        op: "scf.while",
        ip: block,
        ctx: ctx,
        arguments: [state_found, state_result, state_cursor],
        results: [i64, i64, i64],
        loc: MLIR.Location.unknown(),
        filler: fn -> [before, after_region] end
      }
      |> MLIR.Operation.create()

    [found, result, _cursor] = while_op |> MLIR.Operation.results() |> Enum.to_list()
    found_i1 = create_op("arith.trunci", [cmp(found, 0, "ne", ctx, block)], [i1], ctx, block)
    nil_dyn = create_op("ex.nil_word", [], [ex_type("dyn", ctx)], ctx, block)
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

  defp ensure_receive_catch_all(clauses) do
    if catch_all_clause?(List.last(clauses)) do
      clauses
    else
      clauses ++ [{:->, [], [[{:_, [], nil}], 0]}]
    end
  end

  defp lift_reduce_pattern(
         pattern,
         enumerable_ast,
         enumerable_word,
         acc_value,
         ctx,
         block,
         env
       ) do
    case pattern do
      :sum ->
        if is_list(enumerable_ast) do
          # A list literal keeps the compile-time cursor loop (M3); other
          # enumerables (tuple/binary literals or variables) dispatch through
          # the runtime's tag-based enumerable reduce.
          {lift_enum_sum_loop(enumerable_word, acc_value, ctx, block, env[:__budget__]), env}
        else
          {lift_enum_reduce_runtime(enumerable_word, acc_value, 1, ctx, block), env}
        end

      :product ->
        if is_list(enumerable_ast) do
          {lift_enum_product_loop(enumerable_word, acc_value, ctx, block, env[:__budget__]), env}
        else
          {lift_enum_reduce_runtime(enumerable_word, acc_value, 6, ctx, block), env}
        end

      :subtract_acc_first ->
        if is_list(enumerable_ast) do
          {lift_enum_subtract_loop(
             enumerable_word,
             acc_value,
             :acc_first,
             ctx,
             block,
             env[:__budget__]
           ), env}
        else
          {lift_enum_reduce_runtime(enumerable_word, acc_value, 7, ctx, block), env}
        end

      :subtract_item_first ->
        if is_list(enumerable_ast) do
          {lift_enum_subtract_loop(
             enumerable_word,
             acc_value,
             :item_first,
             ctx,
             block,
             env[:__budget__]
           ), env}
        else
          {lift_enum_reduce_runtime(enumerable_word, acc_value, 8, ctx, block), env}
        end

      :div_acc_first ->
        # Integer division/remainder reduce through the runtime (the ex
        # dialect has no div/rem ops).
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 9, ctx, block), env}

      :div_item_first ->
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 10, ctx, block), env}

      :rem_acc_first ->
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 11, ctx, block), env}

      :rem_item_first ->
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 12, ctx, block), env}

      {:capture_sum, capture_ast} ->
        {capture, env} = lift_expr(capture_ast, ctx, block, env)
        capture_i64 = enum_capture_i64(capture, ctx, block)
        {lift_enum_reduce_capture(enumerable_word, acc_value, capture_i64, ctx, block), env}

      {:capture_product, capture_ast} ->
        {capture, env} = lift_expr(capture_ast, ctx, block, env)
        capture_i64 = enum_capture_i64(capture, ctx, block)
        {lift_enum_reduce_capture(enumerable_word, acc_value, capture_i64, ctx, block, 14), env}

      {:combination, reducer_name} ->
        # Any enumerable: the reducer was extracted to `__enum_reducer_N`,
        # whose address is handed to the runtime's arbitrary-closure reduce.
        addr =
          create_op(
            "ex.func_addr",
            [sym_name: MLIR.Attribute.string(to_string(reducer_name))],
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

      :map_values_sum ->
        # Map reduce sums entry values through runtime continuation 3.
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 3, ctx, block), env}

      :map_keys_sum ->
        # Map reduce sums entry keys through runtime continuation 4.
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 4, ctx, block), env}

      :map_entries_sum ->
        # Map reduce sums key + value per entry through runtime continuation 5.
        {lift_enum_reduce_runtime(enumerable_word, acc_value, 5, ctx, block), env}

      :return_acc ->
        {acc_value, env}
    end
  end

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

  # Logical-clock mapping (#35 slice 8): `erlang.monotonic_time/0,1` reads the
  # runtime's native clock (nanoseconds) and converts to the requested unit;
  # `erlang.unique_integer/0,1` hands out fresh increasing (or, for
  # `:negative`, decreasing) values from the runtime counter.
  defp lift_stdlib_call(:erlang, :monotonic_time, [], ctx, block, env) do
    {create_op("ex.native_time", [], [integer_type(ctx)], ctx, block), env}
  end

  defp lift_stdlib_call(:erlang, :monotonic_time, [unit_ast], ctx, block, env) do
    divisor =
      case unit_ast do
        :native -> 1
        :nanosecond -> 1
        :microsecond -> 1_000
        :millisecond -> 1_000_000
        :second -> 1_000_000_000
        :minute -> 60 * 1_000_000_000
        :hour -> 3_600 * 1_000_000_000
        :day -> 86_400 * 1_000_000_000
        unit when is_integer(unit) and unit > 0 -> unit
        _ -> raise Error, "unsupported monotonic_time unit: #{inspect(unit_ast)}"
      end

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
        [ex_type("dyn", ctx)],
        ctx,
        block
      ),
      env
    }
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

  # Lowering for `:native_term` registry entries: operands arrive boxed as
  # `!ex.dyn` words, results are either scalar i64 or `!ex.dyn`.
  defp native_term_call(module, :length, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :hd, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(module, :tl, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.list_tail", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(module, :tuple_size, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Map, :size, [value], ctx, block),
    do: create_op("ex.map_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Tuple, :size, [value], ctx, block),
    do: create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :byte_size, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.binary_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :map_size, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.map_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Enum, :count, [value], ctx, block),
    do: create_op("ex.enumerable_count", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Enum, :to_list, [value], ctx, block),
    do: create_op("ex.enumerable_to_list", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(String, :length, [value], ctx, block),
    do: create_op("ex.binary_utf8_length", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(String, :to_integer, [value], ctx, block),
    do: create_op("ex.string_to_int", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(Base, :encode16, [value], ctx, block),
    do: create_op("ex.binary_encode16", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(Base, :decode16, [value], ctx, block),
    do: create_op("ex.binary_decode16", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(Integer, :to_string, [value], ctx, block),
    do: create_op("ex.int_to_string", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(MapSet, :new, [value], ctx, block),
    do: create_op("ex.mapset_from_list", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(HashSet, :new, [value], ctx, block),
    do: create_op("ex.mapset_from_list", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(MapSet, :member?, [set, member], ctx, block),
    do: create_op("ex.mapset_member", [set, member], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(MapSet, :put, [set, member], ctx, block),
    do: create_op("ex.mapset_put", [set, member], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(Stream, :take, [list, n], ctx, block) do
    n_int = create_op("ex.to_int", [n], [integer_type(ctx)], ctx, block)
    create_op("ex.stream_take", [list, n_int], [ex_type("dyn", ctx)], ctx, block)
  end

  defp native_term_call(Stream, :drop, [list, n], ctx, block) do
    n_int = create_op("ex.to_int", [n], [integer_type(ctx)], ctx, block)
    create_op("ex.stream_drop", [list, n_int], [ex_type("dyn", ctx)], ctx, block)
  end

  defp native_term_call(File, :read!, [path], ctx, block),
    do: create_op("ex.file_read", [path], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(File, :stream!, [path], ctx, block),
    do: create_op("ex.file_read_lines", [path], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(_module, :elem, [tuple, index], ctx, block) do
    index_int = create_op("ex.to_int", [index], [MLIR.Type.i64()], ctx, block)
    index0 = create_op("ex.sub", [index_int, lit(1, ctx, block)], [MLIR.Type.i64()], ctx, block)
    create_op("ex.tuple_get", [tuple, index0], [ex_type("dyn", ctx)], ctx, block)
  end

  defp native_term_call(module, :is_atom, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_atom", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_binary, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_binary", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_integer, [value], ctx, block)
       when module in [Kernel, :erlang],
       do: create_op("ex.is_integer", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_list, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_list", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_map, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_map", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(module, :is_tuple, [value], ctx, block) when module in [Kernel, :erlang],
    do: create_op("ex.is_tuple", [value], [MLIR.Type.i64()], ctx, block)

  defp native_term_call(_module, :first, [value], ctx, block),
    do: create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(_module, :self, [], ctx, block),
    do: create_op("ex.self", [], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(_module, :send, [pid, msg], ctx, block),
    do: create_op("ex.send", [pid, msg], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(_module, :spawn, [fun], ctx, block),
    do: create_op("ex.spawn", [fun], [ex_type("dyn", ctx)], ctx, block)

  defp native_term_call(module, fun, _args, _ctx, _block) do
    raise Error, "no native_term lowering for #{inspect(module)}.#{fun}"
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
  defp lift_value({:fn_ref, fn_idx, _name, _arity, captured}, ctx, block, env) do
    env_values = resolve_captured(captured, env)

    unless length(env_values) <= 4 do
      raise Error, "anonymous function capture exceeds 4 slots: #{length(env_values)}"
    end

    create_op(
      "ex.make_fun",
      env_values ++
        [
          fn_idx: MLIR.Attribute.integer(MLIR.Type.i64(), fn_idx),
          env_len: MLIR.Attribute.integer(MLIR.Type.i64(), length(captured)),
          operandSegmentSizes:
            segment_sizes(
              List.duplicate(1, length(captured)) ++ List.duplicate(0, 4 - length(captured))
            )
        ],
      [ex_type("dyn", ctx)],
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
  defp cmp_predicate(:<), do: "slt"
  defp cmp_predicate(:<=), do: "sle"
  defp cmp_predicate(:>), do: "sgt"
  defp cmp_predicate(:>=), do: "sge"

  defp lift_case(clauses, scrutinee, env, ctx, block, opts \\ []) do
    if Enum.any?(clauses, &(clause_pattern(&1) |> term_pattern?())) do
      lift_term_case(clauses, scrutinee, env, ctx, block, opts)
    else
      lift_scalar_case(clauses, scrutinee, env, ctx, block, opts)
    end
  end

  defp lift_scalar_case(clauses, scrutinee, env, ctx, block, opts) do
    parsed = Enum.map(clauses, &parse_clause/1)

    unless parsed |> List.last() |> Map.fetch!(:patterns) == [] do
      raise Error, "case requires a final catch-all clause"
    end

    guards =
      Enum.map(parsed, fn clause ->
        case clause.guard do
          nil -> nil
          guard_ast -> lift_guard(guard_ast, clause.vars, scrutinee, env, ctx, block)
        end
      end)

    region = MLIR.CAPI.mlirRegionCreate()

    yield_types =
      parsed
      |> Enum.zip(guards)
      |> Enum.map(fn {clause, guard} ->
        add_clause_block(clause, guard, scrutinee, env, ctx, region)
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
        create_op("ex.to_word", [scrutinee], [ex_type("dyn", ctx)], ctx, block)
      end

    {guards, bindss} =
      parsed
      |> Enum.map(fn clause ->
        {match_cond, binds} =
          build_match(clause.pattern, scrutinee, ctx, block, clause.guard == nil)

        cond =
          case clause.guard do
            nil ->
              match_cond

            guard_ast ->
              guard_cond = lift_term_guard(guard_ast, binds, env, ctx, block)
              combine([match_cond, guard_cond], ctx, block)
          end

        {cond, binds}
      end)
      |> Enum.unzip()

    # `receive` clauses guard integer messages with `is_integer(x)`; the
    # bound word is untagged so the clause body can use it in scalar
    # arithmetic.
    bindss =
      if Keyword.get(opts, :untag_int_binds, false) do
        untag_int_binds(parsed, bindss, ctx, block)
      else
        bindss
      end

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

  defp untag_int_binds(parsed, bindss, ctx, block) do
    parsed
    |> Enum.zip(bindss)
    |> Enum.map(fn {%{guard: guard}, binds} ->
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
    end)
  end

  defp integer_guard_var({:is_integer, _, [{var, _, nil}]}) when is_atom(var), do: var
  defp integer_guard_var(_guard), do: nil

  # The match condition and the bound values of one term pattern are computed
  # eagerly before `ex.case`: predicates and reads are pure and safe on the
  # wrong term kind (reads return nil), so a non-matching clause's eager
  # values are simply unused. The combined condition becomes the clause guard.
  # `defer_rest?` moves the rest-slice materialization of a top-level binary
  # pattern into the clause body (expandable 210418e): without a guard, the
  # slice is only needed when the clause matches, so a rejected clause never
  # allocates it.
  defp build_match(pattern, value, ctx, block, defer_rest?) do
    case pattern do
      {:<<>>, _, segments} -> build_binary_match(segments, value, ctx, block, defer_rest?)
      _ -> do_build_match(pattern, value, ctx, block)
    end
  end

  defp do_build_match({name, _, nil}, value, _ctx, _block) when is_atom(name) do
    if name == :_ do
      {nil, []}
    else
      {nil, [{name, value}]}
    end
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

    head_value = create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("dyn", ctx)], ctx, block)
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
            [ex_type("dyn", ctx)],
            ctx,
            block
          )

        {cond, element_binds} = do_build_match(element, element_value, ctx, block)
        {cond, element_binds ++ binds}
      end)

    {combine([cond_tuple, cond_len | elem_conds], ctx, block), Enum.reverse(binds)}
  end

  defp list_elements_match([], _value, _ctx, _block, binds), do: {[], binds}

  defp list_elements_match([element | rest], value, ctx, block, binds) do
    head_value = create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("dyn", ctx)], ctx, block)
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
                [ex_type("dyn", ctx)],
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
              create_op("ex.binary_utf8_get", [value, offset], [ex_type("dyn", ctx)], ctx, block)

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
      create_op("ex.binary_slice", [value, offset], [ex_type("dyn", ctx)], ctx, clause_block)
    end

    {nil, [{name, {:deferred, slice}}]}
  end

  defp build_rest_bind(rest_pat, value, offset, ctx, block, _defer_rest?) do
    rest_value =
      create_op("ex.binary_slice", [value, offset], [ex_type("dyn", ctx)], ctx, block)

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

    {value, clause_env} = lift_block(List.wrap(clause.body), ctx, block, clause_env)
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
  # calls on bound or outer variables. Comparisons and arithmetic on terms
  # are rejected explicitly.
  defp lift_term_guard(guard_ast, binds, env, ctx, block) do
    unless supported_term_guard?(guard_ast) do
      raise Error,
            "unsupported guard on term pattern (only is_* predicates on bound or outer variables): " <>
              inspect(guard_ast)
    end

    guard_env = Map.merge(env, Map.new(binds))
    {value, _env} = lift_expr(guard_ast, ctx, block, guard_env)
    value
  end

  defp supported_term_guard?({predicate, _, [var_ast]})
       when predicate in [:is_integer, :is_atom, :is_binary, :is_list, :is_tuple, :is_map] do
    match?({name, _, nil} when is_atom(name), var_ast)
  end

  defp supported_term_guard?({op, _, [left, right]}) when op in [:==, :!=] do
    guard_operand?(left) and guard_operand?(right)
  end

  defp supported_term_guard?(_guard_ast), do: false

  defp guard_operand?(value) when is_integer(value), do: true
  defp guard_operand?(value) when is_binary(value), do: true
  defp guard_operand?({name, _, nil}) when is_atom(name), do: true
  defp guard_operand?({:<<>>, _, _}), do: true
  defp guard_operand?({:%{}, _, _}), do: true
  defp guard_operand?(tuple) when is_tuple(tuple) and tuple_size(tuple) != 3, do: true

  defp guard_operand?(_), do: false

  defp term_operand?(value) do
    value
    |> MLIR.Value.type()
    |> MLIR.to_string()
    |> then(&(&1 in ["!ex.dyn", "!ex.bound", "!ex.unbound"]))
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

  defp term_pattern?(pattern) do
    pattern
    |> PatternPlan.lower_pattern()
    |> Enum.any?(&(&1.op in [:tuple, :list_exact, :list_cons, :binary]))
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
    {value, _env} = lift_expr(guard_ast, ctx, block, guard_env)
    value
  end

  defp add_clause_block(clause, guard, scrutinee, env, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    clause_env = Enum.reduce(clause.vars, env, fn var, acc -> Map.put(acc, var, scrutinee) end)

    clause_attrs = [patterns: pattern_attr(clause.patterns)]
    clause_args = if guard, do: [guard], else: []
    create_op("ex.clause", clause_args ++ clause_attrs, [], ctx, block)

    {value, clause_env} = lift_block(List.wrap(clause.body), ctx, block, clause_env)
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
    create_op("ex.box", [value], [ex_type("dyn", ctx)], ctx, block)
  end

  defp lift_map_entries(entries, ctx, block, env) do
    Enum.flat_map_reduce(entries, env, fn entry, env ->
      case entry do
        {key, _value} when is_atom(key) ->
          raise Error,
                "atom-keyed map entries are unsupported in the term slice: #{inspect(entry)}"

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

  defp create_term_op(op_name, args, ctx, block) do
    create_op(
      op_name,
      args ++ [operandSegmentSizes: segment_sizes([length(args)])],
      [ex_type("dyn", ctx)],
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

  defp integer_type(ctx), do: MLIR.Type.integer(64, ctx: ctx)

  defp ex_type(name, ctx) do
    Beaver.Slang.create_constrained_element(:type, "ex", name, [], ctx: ctx)
    |> Beaver.Deferred.create(ctx)
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
