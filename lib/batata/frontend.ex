defmodule Batata.Frontend do
  @moduledoc """
  Normalized boundary for already-expanded Elixir modules.

  This module deliberately does not implement macro expansion or compile-time
  semantics: it records a normalized module snapshot so later phases can
  consume function clauses without owning them (the frontend boundary of the
  M1 plan).
  """

  defmodule Module do
    @moduledoc "A normalized module snapshot at the expanded-module boundary."
    @enforce_keys [:name, :definitions]
    defstruct [:name, definitions: [], unsupported: []]
  end

  defmodule Definition do
    @moduledoc "One normalized function definition with one or more clauses."
    @enforce_keys [:kind, :name, :arity, :clauses]
    defstruct [:kind, :name, :arity, clauses: []]
  end

  defmodule Clause do
    @moduledoc "One function clause with patterns and a body AST."
    @enforce_keys [:patterns, :body_ast]
    defstruct [:patterns, :body_ast]
  end

  defmodule UnsupportedForm do
    @moduledoc "A module-body form outside the frontend boundary."
    @enforce_keys [:form, :reason]
    defstruct [:form, :reason]
  end

  @doc """
  Parses source text and normalizes the resulting module AST.

  This parses only. It does not call `Macro.expand/2` or the Elixir compiler.
  """
  @spec from_source(String.t()) :: Module.t()
  def from_source(source) when is_binary(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    from_ast(ast)
  end

  @doc """
  Normalizes an already-parsed `defmodule` AST.
  """
  @spec from_ast(Macro.t()) :: Module.t()
  def from_ast({:defmodule, _, [{:__aliases__, _, name_parts}, [do: body]]}) do
    {definitions, unsupported} = body |> body_forms() |> normalize_body()

    %Module{
      name: Elixir.Module.concat(name_parts),
      definitions: definitions,
      unsupported: unsupported
    }
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp normalize_body(forms) do
    Enum.map_reduce(forms, [], fn form, unsupported ->
      case normalize_form(form) do
        {:ok, definition} ->
          {definition, unsupported}

        {:unsupported, reason} ->
          {nil, [%UnsupportedForm{form: form, reason: reason} | unsupported]}
      end
    end)
    |> then(fn {definitions, unsupported} ->
      {Enum.reject(definitions, &is_nil/1), Enum.reverse(unsupported)}
    end)
  end

  defp normalize_form({kind, _, [{name, _, args}, [do: body_ast]]})
       when kind in [:def, :defp] and is_atom(name) do
    {:ok,
     %Definition{
       kind: kind,
       name: name,
       arity: length(args),
       clauses: [%Clause{patterns: args, body_ast: body_ast}]
     }}
  end

  defp normalize_form({:@, _, _}), do: {:unsupported, :module_attribute}
  defp normalize_form({:require, _, _}), do: {:unsupported, :require}
  defp normalize_form({:import, _, _}), do: {:unsupported, :import}
  defp normalize_form({:use, _, _}), do: {:unsupported, :use}
  defp normalize_form({:defmodule, _, _}), do: {:unsupported, :nested_defmodule}
  defp normalize_form(other), do: {:unsupported, :unknown_form}
end
