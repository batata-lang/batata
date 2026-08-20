defmodule Batata.Frontend.UnicodeEscapeMacroExpand do
  @moduledoc """
  Expands bounded nested providers for hexadecimal Unicode escape case tables.

  The provider is recognized structurally and is never compiled or executed.
  Its three public macros are replaced with finite case tables over JSON's
  hexadecimal digit alphabet, after which the compile-time-only nested module
  and its scoped `require` declarations are removed.
  """

  @digits Enum.to_list(?0..?9) ++ Enum.to_list(?A..?F) ++ Enum.to_list(?a..?f)
  @max_clauses 512
  @signatures MapSet.new(escapeu_first: 8, escapeu_last: 3, escapeu_surrogate: 9)

  @doc "Expands one supported nested Unicode escape provider."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [module_ast, [do: body]]}) do
    forms = body_forms(body)

    case find_provider(forms, module_ast) do
      {:ok, provider_module, provider_form} ->
        forms =
          forms
          |> Enum.reject(&(&1 == provider_form))
          |> Enum.map(&rewrite_form(&1, provider_module))

        {:defmodule, metadata, [module_ast, [do: block(forms)]]}

      :error ->
        {:defmodule, metadata, [module_ast, [do: body]]}
    end
  end

  def expand(ast), do: ast

  defp find_provider(forms, parent_ast) do
    Enum.find_value(forms, :error, &provider(&1, parent_ast))
  end

  defp provider({:defmodule, _, [nested_ast, [do: nested_body]]} = form, parent_ast) do
    with true <- supported_provider?(nested_body),
         module when is_atom(module) and not is_nil(module) <-
           qualified_module(parent_ast, nested_ast) do
      {:ok, module, form}
    else
      _ -> nil
    end
  end

  defp provider(_form, _parent_ast), do: nil

  defp supported_provider?(body) do
    forms = body_forms(body)

    signatures =
      forms
      |> Enum.flat_map(fn form ->
        case macro_signature(form) do
          {:ok, signature} -> [signature]
          :error -> []
        end
      end)
      |> MapSet.new()

    MapSet.subset?(@signatures, signatures) and hex_digits_attribute?(forms) and
      unicode_escape_generator?(forms) and
      Enum.all?(@signatures, fn {name, _arity} -> generated_case_macro?(forms, name) end)
  end

  defp hex_digits_attribute?(forms) do
    Enum.any?(forms, fn
      {:@, _,
       [
         {:digits, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :concat]}, _, [ranges]}
          ]}
       ]}
      when is_list(ranges) ->
        ranges
        |> Enum.flat_map(fn
          {:.., _, [first, last]} when is_integer(first) and is_integer(last) ->
            Enum.to_list(first..last)

          _ ->
            []
        end)
        |> Kernel.==(@digits)

      _ ->
        false
    end)
  end

  defp unicode_escape_generator?(forms) do
    Enum.any?(forms, fn
      {:def, _, [head, [do: body]]} ->
        definition_name(head) == :unicode_escapes and
          contains?(body, fn
            {:for, _, [{:<-, _, _}, {:<-, _, _}, [do: _]]} -> true
            _ -> false
          end)

      _ ->
        false
    end)
  end

  defp generated_case_macro?(forms, name) do
    Enum.any?(forms, fn
      {:defmacro, _, [head, [do: body]]} ->
        definition_name(head) == name and contains?(body, &match?({:case, _, _}, &1)) and
          contains?(body, fn
            {helper, _, arguments} when is_atom(helper) and is_list(arguments) ->
              helper == String.to_atom("#{name}_clauses")

            _ ->
              false
          end)

      _ ->
        false
    end)
  end

  defp rewrite_form({kind, metadata, [head, [do: body]]}, provider_module)
       when kind in [:def, :defp] do
    {kind, metadata, [head, [do: rewrite_body(body, provider_module)]]}
  end

  defp rewrite_form(form, _provider_module), do: form

  defp rewrite_body(body, provider_module) do
    Macro.postwalk(body, fn
      {:require, _, [module_ast]} = require ->
        if provider_reference?(module_ast, provider_module), do: nil, else: require

      {{:., _, [module_ast, :escapeu_first]}, metadata, arguments} = call
      when length(arguments) == 8 ->
        if provider_reference?(module_ast, provider_module),
          do: expand_first(arguments, metadata),
          else: call

      {{:., _, [module_ast, :escapeu_last]}, metadata, arguments} = call
      when length(arguments) == 3 ->
        if provider_reference?(module_ast, provider_module),
          do: expand_last(arguments, metadata),
          else: call

      {{:., _, [module_ast, :escapeu_surrogate]}, metadata, arguments} = call
      when length(arguments) == 9 ->
        if provider_reference?(module_ast, provider_module),
          do: expand_surrogate(arguments, metadata),
          else: call

      {:__block__, metadata, forms} ->
        block(forms, metadata)

      node ->
        node
    end)
  end

  defp expand_last([int, original, skip], metadata) do
    clauses =
      for char1 <- @digits, char2 <- @digits do
        {:->, metadata, [[raw_pair(char1, char2)], decoded_byte(char1, char2)]}
      end

    build_case(int, clauses, token_error(original, skip, 6, metadata), metadata)
  end

  defp expand_first([int, last, rest, original, skip, stack, decode, acc], metadata) do
    clauses =
      for char1 <- @digits,
          char2 <- @digits,
          first = decoded_byte(char1, char2),
          first not in 0xDC..0xDF do
        body = first_body(first, last, rest, original, skip, stack, decode, acc)
        {:->, metadata, [[raw_pair(char1, char2)], body]}
      end

    build_case(int, clauses, token_error(original, skip, 6, metadata), metadata)
  end

  defp expand_surrogate([int, last, rest, original, skip, stack, decode, acc, hi], metadata) do
    clauses =
      for char1 <- ~c"Dd", char2 <- ~c"CDEFcdef" do
        first = decoded_byte(char1, char2)

        body = surrogate_body(first, [last, rest, original, skip, stack, decode, acc, hi])

        {:->, metadata, [[raw_pair(char1, char2)], body]}
      end

    build_case(int, clauses, token_error(original, skip, 12, metadata), metadata)
  end

  defp first_body(first, last, rest, original, skip, stack, decode, acc)
       when first in 0xD8..0xDB do
    high_prefix = 0x10000 + rem(first, 4) * 256 * 1024

    quote generated: true do
      escape_surrogate(
        unquote(rest),
        unquote(original),
        unquote(skip),
        unquote(stack),
        unquote(decode),
        unquote(acc),
        unquote(high_prefix) + unquote(last) * 1024
      )
    end
  end

  defp first_body(first, last, rest, original, skip, stack, decode, acc) when first <= 0x07 do
    byte1_base = 0xC0 + first * 4

    quote generated: true do
      updated_acc =
        if unquote(first) == 0 and unquote(last) <= 0x7F do
          [unquote(acc), unquote(last)]
        else
          [
            unquote(acc),
            unquote(byte1_base) + div(unquote(last), 64),
            0x80 + rem(unquote(last), 64)
          ]
        end

      string(
        unquote(rest),
        unquote(original),
        unquote(skip) + 6,
        unquote(stack),
        unquote(decode),
        updated_acc,
        0
      )
    end
  end

  defp first_body(first, last, rest, original, skip, stack, decode, acc) do
    byte1 = 0xE0 + div(first, 16)
    byte2_base = 0x80 + rem(first, 16) * 4

    quote generated: true do
      updated_acc = [
        unquote(acc),
        unquote(byte1),
        unquote(byte2_base) + div(unquote(last), 64),
        0x80 + rem(unquote(last), 64)
      ]

      string(
        unquote(rest),
        unquote(original),
        unquote(skip) + 6,
        unquote(stack),
        unquote(decode),
        updated_acc,
        0
      )
    end
  end

  defp surrogate_body(first, [last, rest, original, skip, stack, decode, acc, hi]) do
    low_prefix = rem(first, 4) * 256

    quote generated: true do
      low = unquote(low_prefix) + unquote(last)
      updated_acc = [unquote(acc) | <<unquote(hi) + low::utf8>>]

      string(
        unquote(rest),
        unquote(original),
        unquote(skip) + 12,
        unquote(stack),
        unquote(decode),
        updated_acc,
        0
      )
    end
  end

  defp build_case(int, clauses, fallback, metadata) when length(clauses) < @max_clauses do
    catchall = {:->, metadata, [[{:_, metadata, nil}], fallback]}
    {:case, metadata, [int, [do: clauses ++ [catchall]]]}
  end

  defp token_error(original, skip, length, metadata),
    do: {:token_error, metadata, [original, skip, length]}

  defp raw_pair(char1, char2), do: char1 * 256 + char2
  defp decoded_byte(char1, char2), do: hex_value(char1) * 16 + hex_value(char2)

  defp hex_value(char) when char in ?0..?9, do: char - ?0
  defp hex_value(char) when char in ?A..?F, do: char - ?A + 10
  defp hex_value(char) when char in ?a..?f, do: char - ?a + 10

  defp provider_reference?({:__aliases__, _, parts}, provider_module) do
    provider_parts = provider_module |> Module.split() |> Enum.map(&String.to_atom/1)
    parts == provider_parts or List.last(parts) == List.last(provider_parts)
  end

  defp provider_reference?(module, provider_module) when is_atom(module),
    do: module == provider_module

  defp provider_reference?(_module_ast, _provider_module), do: false

  defp qualified_module(parent_ast, {:__aliases__, _, nested_parts}) do
    with {:__aliases__, _, parent_parts} <- parent_ast,
         true <- Enum.all?(parent_parts ++ nested_parts, &is_atom/1) do
      Module.concat(parent_parts ++ nested_parts)
    else
      _ -> nil
    end
  end

  defp qualified_module(_parent_ast, _nested_ast), do: nil

  defp macro_signature({:defmacro, _, [head, [do: _body]]}), do: definition_signature(head)
  defp macro_signature(_form), do: :error

  defp definition_signature({name, _, arguments}) when is_atom(name) and is_list(arguments),
    do: {:ok, {name, length(arguments)}}

  defp definition_signature(_head), do: :error

  defp definition_name({name, _, arguments}) when is_atom(name) and is_list(arguments), do: name
  defp definition_name(_head), do: nil

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms), do: block(forms, [])

  defp block(forms, metadata) do
    case Enum.reject(forms, &is_nil/1) do
      [] -> nil
      [form] -> form
      forms -> {:__block__, metadata, forms}
    end
  end
end
