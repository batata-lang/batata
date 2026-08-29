defmodule Batata.Frontend.KernelRaiseExpand do
  @moduledoc """
  Normalizes supported Kernel raise boundaries without macro expansion.

  Source parsing retains auto-imported `raise/1` and `raise/2` as unqualified
  calls. Keep genuine local definitions untouched, but mark imported and
  explicitly qualified Kernel calls so lift cannot mistake them for
  module-local symbols.
  """

  @exception_kind 9
  @argument_error_kind 6
  @protocol_undefined_kind 10

  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    {:defmodule, metadata, [name_ast, [do: rewrite_body(body)]]}
  end

  def expand({:defimpl, metadata, [protocol, options, [do: body]]}) do
    {:defimpl, metadata, [protocol, options, [do: rewrite_body(body)]]}
  end

  def expand(ast), do: ast

  defp rewrite_body(body) do
    forms = body_forms(body)
    local_raise_arities = local_raise_arities(forms)
    forms = Enum.map(forms, &rewrite_form(&1, local_raise_arities))
    block(forms)
  end

  defp rewrite_form({kind, metadata, [head, [do: body]]}, local_raise_arities)
       when kind in [:def, :defp] do
    {kind, metadata, [head, [do: rewrite_calls(body, local_raise_arities)]]}
  end

  defp rewrite_form(form, _local_raise_arities), do: form

  defp rewrite_calls(ast, local_raise_arities) do
    Macro.prewalk(ast, fn
      {:raise, _metadata, arguments} = call when length(arguments) in [1, 2] ->
        if MapSet.member?(local_raise_arities, length(arguments)),
          do: call,
          else: normalize_raise(call, arguments)

      {{:., _, [module_ast, :raise]}, _, arguments} = call when length(arguments) in [1, 2] ->
        if kernel_module?(module_ast),
          do: normalize_raise(call, arguments),
          else: call

      node ->
        node
    end)
  end

  defp normalize_raise(_call, [reason]),
    do: {:__batata_raise__, [], [@exception_kind, reason]}

  defp normalize_raise(call, [exception, attributes]) do
    case exception_module(exception) do
      ArgumentError ->
        case argument_error_message(attributes) do
          {:ok, message} -> {:__batata_raise__, [], [@argument_error_kind, message]}
          :error -> call
        end

      Protocol.UndefinedError ->
        case protocol_undefined_payload(attributes) do
          {:ok, payload} -> {:__batata_raise__, [], [@protocol_undefined_kind, payload]}
          :error -> call
        end

      _other ->
        call
    end
  end

  defp argument_error_message(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes), do: Keyword.fetch(attributes, :message), else: :error
  end

  defp argument_error_message(attributes), do: {:ok, attributes}

  defp protocol_undefined_payload(attributes) when is_list(attributes) do
    with true <- Keyword.keyword?(attributes),
         {:ok, protocol} <- Keyword.fetch(attributes, :protocol),
         {:ok, value} <- Keyword.fetch(attributes, :value) do
      description = Keyword.get(attributes, :description)

      {:ok,
       {:%{}, [],
        [
          __struct__: Protocol.UndefinedError,
          __exception__: true,
          protocol: protocol,
          value: value,
          description: description
        ]}}
    else
      _other -> :error
    end
  end

  defp protocol_undefined_payload(_attributes), do: :error

  defp local_raise_arities(forms) do
    forms
    |> Enum.flat_map(fn
      {kind, _, [head, [do: _body]]} when kind in [:def, :defp] ->
        case signature(head) do
          {:raise, arity} -> [arity]
          _other -> []
        end

      _form ->
        []
    end)
    |> MapSet.new()
  end

  defp exception_module(module) when is_atom(module), do: module

  defp exception_module({:__aliases__, _, parts}) when is_list(parts),
    do: Module.concat(parts)

  defp exception_module(_module), do: nil

  defp signature({:when, _, [head | _guards]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp signature(_head), do: nil

  defp kernel_module?(Kernel), do: true
  defp kernel_module?({:__aliases__, _, [:Kernel]}), do: true
  defp kernel_module?(_module), do: false

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block([form]), do: form
  defp block(forms), do: {:__block__, [], forms}
end
