defmodule Batata.Transform.PatternPlan do
  @moduledoc """
  Structured pattern lowering for case clauses (tsai/beaver#23, step 1).

  Borrows `Expandable.Pattern`'s shape: a `case` expression lowers to a
  `Plan` of `ClausePlan`s, and each pattern lowers to an ordered list of
  `Step`s. A later match-lowering pass (step 2) consumes these plans without
  re-parsing clause AST shapes.

  The current subset covers integer literals, `_`/variables, and
  tuple/list patterns (exact and cons), and atom-keyed map patterns. Anything else lowers to an
  `:unsupported` step so the eventual lowering rejects it explicitly instead
  of guessing.
  """

  defmodule Plan do
    @moduledoc "Pattern lowering for one case expression."
    defstruct [:scrutinee, clauses: []]

    @type t :: %__MODULE__{
            scrutinee: Macro.t(),
            clauses: [Batata.Transform.PatternPlan.ClausePlan.t()]
          }
  end

  defmodule ClausePlan do
    @moduledoc "Lowered pattern and guard steps for one clause."
    defstruct [:pattern, :guard, :body, steps: [], vars: [], refinements: []]
    @type t :: %__MODULE__{}
  end

  defmodule Step do
    @moduledoc "One structural pattern operation."
    defstruct [:op, path: [], value: nil]
  end

  defmodule GuardRefinement do
    @moduledoc "A supported guard predicate applied to a bound pattern path."
    defstruct [:var, :path, :predicate, :type]
    @type t :: %__MODULE__{}
  end

  @type_predicates ~w(is_integer is_atom is_binary is_list is_tuple is_map)a

  @type step :: %Step{op: atom(), path: list(), value: term()}

  @doc "Lowers case clause AST into a plan."
  @spec lower_case(Macro.t(), [Macro.t()]) :: Plan.t()
  def lower_case(scrutinee_ast, clauses) do
    %Plan{scrutinee: scrutinee_ast, clauses: Enum.map(clauses, &lower_clause/1)}
  end

  @doc "Lowers one case clause into a clause plan."
  @spec lower_clause(Macro.t()) :: ClausePlan.t()
  def lower_clause({:->, _, [args, body]}) when is_list(args) do
    {pattern, guard} =
      case args do
        [{:when, _, [pattern, guard]}] ->
          {pattern, guard}

        [pattern] ->
          {pattern, nil}

        _ ->
          raise ArgumentError, "clauses with multiple patterns are unsupported: #{inspect(args)}"
      end

    steps = lower_pattern(pattern, [0])
    {_literals, vars} = pattern_vars(pattern)
    refinements = if guard, do: guard_refinements(guard, vars), else: []

    %ClausePlan{
      pattern: pattern,
      guard: guard,
      body: body,
      steps: steps,
      vars: vars,
      refinements: refinements
    }
  end

  @doc "Lowers one pattern into an ordered list of structural steps."
  @spec lower_pattern(Macro.t(), list()) :: [step()]
  def lower_pattern(pattern, path \\ []) do
    do_lower_pattern(pattern, path)
  end

  @doc "Extracts supported guard refinements for the bound pattern variables."
  @spec guard_refinements(Macro.t(), [atom()]) :: [GuardRefinement.t()]
  def guard_refinements(guard, vars) do
    guard
    |> Macro.prewalk([], fn ast, acc -> collect_guard_refinement(ast, acc, vars) end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp collect_guard_refinement(
         {predicate, _, [{name, _, nil}]} = ast,
         acc,
         vars
       )
       when predicate in @type_predicates and is_atom(name) do
    if name in vars do
      refinement = %GuardRefinement{
        var: name,
        path: [],
        predicate: predicate,
        type: type(predicate)
      }

      {ast, [refinement | acc]}
    else
      {ast, acc}
    end
  end

  defp collect_guard_refinement(ast, acc, _vars), do: {ast, acc}

  defp type(:is_integer), do: :integer
  defp type(:is_atom), do: :atom
  defp type(:is_binary), do: :binary
  defp type(:is_list), do: :list
  defp type(:is_tuple), do: :tuple
  defp type(:is_map), do: :map

  defp do_lower_pattern(integer, path) when is_integer(integer) do
    [%Step{op: :literal, path: path, value: integer}]
  end

  defp do_lower_pattern({name, _, nil}, path) when is_atom(name) do
    if name == :_ do
      [%Step{op: :wildcard, path: path}]
    else
      [%Step{op: :bind, path: path, value: name}]
    end
  end

  defp do_lower_pattern([head | tail], path) when not is_list(tail) do
    [
      %Step{op: :list_cons, path: path},
      %Step{op: :list_head, path: path ++ [:head]},
      %Step{op: :list_tail, path: path ++ [:tail]}
    ] ++
      do_lower_pattern(head, path ++ [:head]) ++
      do_lower_pattern(tail, path ++ [:tail])
  end

  # `[h | t]` parses as a one-element list wrapping the cons op.
  defp do_lower_pattern([{:|, _, [head, tail]}], path) do
    [
      %Step{op: :list_cons, path: path},
      %Step{op: :list_head, path: path ++ [:head]},
      %Step{op: :list_tail, path: path ++ [:tail]}
    ] ++
      do_lower_pattern(head, path ++ [:head]) ++
      do_lower_pattern(tail, path ++ [:tail])
  end

  defp do_lower_pattern([head | tail] = elements, path) do
    if list_pattern_has_cons_tail?(tail) do
      [
        %Step{op: :list_cons, path: path},
        %Step{op: :list_head, path: path ++ [:head]},
        %Step{op: :list_tail, path: path ++ [:tail]}
      ] ++
        do_lower_pattern(head, path ++ [:head]) ++
        do_lower_pattern(tail, path ++ [:tail])
    else
      [%Step{op: :list_exact, path: path, value: length(elements)}] ++
        lower_indexed(elements, path)
    end
  end

  defp do_lower_pattern({:%{}, _, entries}, path) do
    if Enum.all?(entries, &supported_map_entry?/1) do
      [%Step{op: :map, path: path, value: Enum.map(entries, &elem(&1, 0))}]
    else
      [%Step{op: :unsupported, path: path, value: {:%{}, [], entries}}]
    end
  end

  defp do_lower_pattern({:<>, metadata, [prefix, {name, variable_metadata, context}]}, path)
       when is_binary(prefix) and byte_size(prefix) > 0 and is_atom(name) and name != :_ and
              is_atom(context) do
    rest_pattern = {name, variable_metadata, context}

    do_lower_pattern(
      {:<<>>, metadata,
       :binary.bin_to_list(prefix) ++
         [
           {:"::", variable_metadata, [rest_pattern, {:binary, variable_metadata, nil}]}
         ]},
      path
    )
  end

  defp do_lower_pattern({:<>, _, [_prefix, _rest]} = pattern, path) do
    [%Step{op: :unsupported, path: path, value: pattern}]
  end

  defp do_lower_pattern({:<<>>, _, segments}, path) do
    segment_steps =
      segments
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:"::", _, [pat, {:binary, _, nil}]}, _index} ->
          [%Step{op: :binary_rest, path: path ++ [:rest]}] ++
            do_lower_pattern(pat, path ++ [:rest])

        {segment, index} ->
          case segment do
            {:"::", _, [pat, {:utf8, _, nil}]} ->
              [%Step{op: :binary_utf8, path: path ++ [{:segment, index}]}] ++
                do_lower_pattern(pat, path ++ [{:segment, index}])

            _ ->
              [%Step{op: :binary_get, path: path ++ [{:segment, index}]}] ++
                do_lower_pattern(byte_pat(segment), path ++ [{:segment, index}])
          end
      end)

    [%Step{op: :binary, path: path, value: length(segments)}] ++ segment_steps
  end

  # Tuple patterns: `{a, b}` and `{a, b, c}` are plain tuples in the AST.
  defp do_lower_pattern(tuple, path)
       when is_tuple(tuple) and tuple_size(tuple) != 3 do
    elements = Tuple.to_list(tuple)

    [%Step{op: :tuple, path: path, value: length(elements)}] ++
      lower_indexed(elements, path)
  end

  defp do_lower_pattern({a, b, c}, path)
       when not (is_atom(a) and is_list(b) and is_list(c)) do
    elements = [a, b, c]

    [%Step{op: :tuple, path: path, value: 3}] ++
      lower_indexed(elements, path)
  end

  # Three-or-more element tuples parse as `{:{}, meta, elements}`.
  defp do_lower_pattern({:{}, _, elements}, path) do
    [%Step{op: :tuple, path: path, value: length(elements)}] ++
      lower_indexed(elements, path)
  end

  defp do_lower_pattern([], path) do
    [%Step{op: :list_exact, path: path, value: 0}]
  end

  defp do_lower_pattern(other, path) do
    [%Step{op: :unsupported, path: path, value: other}]
  end

  defp supported_map_entry?({key, {name, _, nil}})
       when is_atom(key) and is_atom(name),
       do: true

  defp supported_map_entry?(_entry), do: false

  defp byte_pat({:"::", _, [pat, 8]}), do: pat
  defp byte_pat(pat), do: pat

  defp lower_indexed(patterns, path) do
    patterns
    |> Enum.with_index()
    |> Enum.flat_map(fn {pattern, index} ->
      do_lower_pattern(pattern, path ++ [index])
    end)
  end

  defp list_pattern_has_cons_tail?([{:|, _, [_head, _tail]}]), do: true
  defp list_pattern_has_cons_tail?([_head | tail]), do: list_pattern_has_cons_tail?(tail)
  defp list_pattern_has_cons_tail?([]), do: false

  @doc "Returns `{literal_patterns, bound_vars}` for a pattern."
  @spec pattern_vars(Macro.t()) :: {[term()], [atom()]}
  def pattern_vars(pattern) do
    {_ast, {literals, vars}} =
      Macro.prewalk(pattern, {[], []}, fn
        integer, {literals, vars} when is_integer(integer) ->
          {integer, {[integer | literals], vars}}

        {name, _, nil}, {literals, vars} when is_atom(name) ->
          if name == :_ do
            {{name, [], nil}, {literals, vars}}
          else
            {{name, [], nil}, {literals, [name | vars]}}
          end

        ast, acc ->
          {ast, acc}
      end)

    {Enum.reverse(literals), Enum.reverse(vars)}
  end
end
