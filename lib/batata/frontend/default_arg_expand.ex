defmodule Batata.Frontend.DefaultArgExpand do
  @moduledoc """
  Expands function defaults into explicit wrapper arities.

  The rewrite is syntax-only. Each generated wrapper calls the full arity
  directly and evaluates omitted defaults at wrapper invocation time.
  """

  defmodule Error do
    @moduledoc "A deterministic default-argument expansion error."
    defexception [:reason, :function, :message]

    @type t() :: %__MODULE__{
            reason: atom(),
            function: {atom(), non_neg_integer()} | nil,
            message: String.t()
          }
  end

  @type signature :: {:def | :defp, atom(), non_neg_integer()}

  @doc "Expands defaults in the direct body of one module."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    forms = body_forms(body)
    declarations = default_declarations(forms)
    validate_declarations!(declarations, forms)

    expanded = Enum.flat_map(forms, &expand_form/1)
    {:defmodule, metadata, [name_ast, [do: block(expanded)]]}
  end

  def expand(ast), do: ast

  defp default_declarations(forms) do
    forms
    |> Enum.flat_map(&default_declaration/1)
  end

  defp default_declaration(form) do
    case definition(form) do
      %{args: args} = definition when is_list(args) ->
        if Enum.any?(args, &default?/1), do: [definition], else: []

      _ ->
        []
    end
  end

  defp validate_declarations!(declarations, forms) do
    declarations
    |> Enum.group_by(&{&1.kind, &1.name, length(&1.args)})
    |> Enum.each(fn
      {signature, [declaration]} ->
        validate_default_references!(signature, declaration.args)

      {{_kind, name, arity}, _duplicates} ->
        expansion_error!(:duplicate_default_declaration, {name, arity})
    end)

    explicit =
      forms
      |> Enum.flat_map(fn form ->
        case definition(form) do
          %{body: nil} -> []
          %{kind: kind, name: name, args: args} when is_list(args) -> [{kind, name, length(args)}]
          _ -> []
        end
      end)
      |> MapSet.new()

    generated =
      Enum.flat_map(declarations, fn declaration ->
        wrapper_arities(declaration.args)
        |> Enum.map(&{declaration.kind, declaration.name, &1})
      end)

    generated
    |> Enum.frequencies()
    |> Enum.each(fn
      {{_kind, name, arity}, count} when count > 1 ->
        expansion_error!(:default_arity_collision, {name, arity})

      {signature = {_kind, name, arity}, _count} ->
        if MapSet.member?(explicit, signature) do
          expansion_error!(:default_arity_collision, {name, arity})
        end
    end)
  end

  defp validate_default_references!({_kind, name, arity}, args) do
    parameters =
      args
      |> Enum.map(&strip_default/1)
      |> Enum.flat_map(&pattern_variables/1)
      |> MapSet.new()

    Enum.each(args, fn
      {:\\, _, [_pattern, default]} ->
        if references_any?(default, parameters) do
          expansion_error!(:default_arg_param_reference, {name, arity})
        end

      _argument ->
        :ok
    end)
  end

  defp expand_form(form) do
    case definition(form) do
      %{args: args} = definition when is_list(args) ->
        case Enum.any?(args, &default?/1) do
          true -> expand_default_definition(definition)
          false -> [form]
        end

      _ ->
        [form]
    end
  end

  defp expand_default_definition(definition) do
    wrappers = wrappers(definition)

    case definition.body do
      nil ->
        wrappers

      body ->
        wrappers ++
          [build_definition(definition, Enum.map(definition.args, &strip_default/1), body)]
    end
  end

  defp wrappers(%{args: args} = definition) do
    default_indexes =
      args
      |> Enum.with_index()
      |> Enum.filter(fn {argument, _index} -> default?(argument) end)
      |> Enum.map(&elem(&1, 1))

    1..length(default_indexes)
    |> Enum.map(fn omitted_count ->
      omitted = default_indexes |> Enum.take(-omitted_count) |> MapSet.new()

      {wrapper_args, call_args, _next_index} = wrapper_arguments(args, omitted)

      body = {definition.name, [generated: true], call_args}
      build_definition(definition, wrapper_args, body, nil)
    end)
  end

  defp wrapper_arguments(args, omitted) do
    args
    |> Enum.with_index()
    |> Enum.reduce({[], [], 0}, fn argument, acc ->
      append_wrapper_argument(argument, acc, omitted)
    end)
  end

  defp append_wrapper_argument(
         {{:\\, _, [_pattern, default]}, index},
         {params, call, next},
         omitted
       ) do
    if MapSet.member?(omitted, index) do
      {params, call ++ [default], next}
    else
      append_supplied_argument(params, call, next)
    end
  end

  defp append_wrapper_argument({_argument, _index}, {params, call, next}, _omitted) do
    append_supplied_argument(params, call, next)
  end

  defp append_supplied_argument(params, call, next) do
    variable = generated_variable(next)
    {params ++ [variable], call ++ [variable], next + 1}
  end

  defp build_definition(definition, args, body, guard \\ :preserve) do
    head = {definition.name, definition.head_metadata, args}
    guard = if guard == :preserve, do: definition.guard, else: guard
    head = if guard, do: {:when, definition.guard_metadata, [head, guard]}, else: head
    {definition.kind, definition.metadata, [head, [do: body]]}
  end

  defp definition({kind, metadata, [head, [do: body]]}) when kind in [:def, :defp] do
    definition_head(kind, metadata, head, body)
  end

  defp definition({kind, metadata, [head]}) when kind in [:def, :defp] do
    definition_head(kind, metadata, head, nil)
  end

  defp definition(_form), do: nil

  defp definition_head(kind, metadata, {:when, guard_metadata, [head, guard]}, body) do
    case head do
      {name, head_metadata, args} when is_atom(name) and is_list(args) ->
        %{
          kind: kind,
          metadata: metadata,
          name: name,
          head_metadata: head_metadata,
          args: args,
          guard_metadata: guard_metadata,
          guard: guard,
          body: body
        }

      _ ->
        nil
    end
  end

  defp definition_head(kind, metadata, {name, head_metadata, args}, body)
       when is_atom(name) and (is_list(args) or is_atom(args)) do
    %{
      kind: kind,
      metadata: metadata,
      name: name,
      head_metadata: head_metadata,
      args: if(is_list(args), do: args, else: []),
      guard_metadata: [],
      guard: nil,
      body: body
    }
  end

  defp definition_head(_kind, _metadata, _head, _body), do: nil

  defp wrapper_arities(args) do
    default_count = Enum.count(args, &default?/1)
    Enum.to_list((length(args) - default_count)..(length(args) - 1))
  end

  defp default?({:\\, _, [_pattern, _default]}), do: true
  defp default?(_argument), do: false

  defp strip_default({:\\, _, [pattern, _default]}), do: pattern
  defp strip_default(pattern), do: pattern

  defp pattern_variables(pattern) do
    {_pattern, variables} =
      Macro.prewalk(pattern, [], fn
        {name, _, context} = node, variables
        when is_atom(name) and (is_atom(context) or is_nil(context)) and name != :_ ->
          {node, [name | variables]}

        node, variables ->
          {node, variables}
      end)

    variables
  end

  defp references_any?(ast, parameters) do
    {_ast, found?} =
      Macro.traverse(
        ast,
        false,
        fn
          {:@, _, _} = node, found? ->
            {node, {:attribute, found?}}

          node, {:attribute, found?} ->
            {node, {:attribute, found?}}

          {name, _, context} = node, false
          when is_atom(name) and (is_atom(context) or is_nil(context)) ->
            {node, MapSet.member?(parameters, name)}

          node, found? ->
            {node, found?}
        end,
        fn
          {:@, _, _} = node, {:attribute, found?} -> {node, found?}
          node, state -> {node, state}
        end
      )

    found? == true
  end

  defp generated_variable(index),
    do: {String.to_atom("batata_arg#{index}"), [generated: true], __MODULE__}

  defp expansion_error!(reason, {name, arity}) do
    raise Error,
      reason: reason,
      function: {name, arity},
      message: "#{reason} for #{name}/#{arity}"
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block([form]), do: form
  defp block(forms), do: {:__block__, [], forms}
end
