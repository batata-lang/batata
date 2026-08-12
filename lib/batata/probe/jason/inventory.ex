defmodule Batata.Probe.Jason.Inventory do
  @moduledoc """
  Discovers the frontend surface of a pinned Jason source tree.

  The inventory deliberately parses source without expanding macros. It uses
  `Batata.Frontend` for the same module-boundary classification as the compiler
  and augments each unsupported form with a stable, more specific probe reason.
  This makes early frontend failures inspectable without pretending that the
  source compiled further into the pipeline.
  """

  alias Batata.Frontend

  @type unsupported :: %{
          required(:reason) => atom(),
          required(:frontend_reason) => atom(),
          required(:line) => non_neg_integer() | nil,
          required(:form) => String.t()
        }

  @type module_inventory :: %{
          required(:module) => String.t(),
          required(:definitions) => [map()],
          required(:unsupported) => [unsupported()]
        }

  @type file_inventory :: %{
          required(:path) => String.t(),
          required(:digest) => String.t(),
          required(:status) => :parsed | :parse_error,
          required(:modules) => [module_inventory()],
          required(:top_level_unsupported) => [map()],
          optional(:parse_error) => map()
        }

  @doc "Discovers every `.ex` file below a Jason project or `lib` directory."
  @spec discover!(Path.t()) :: [file_inventory()]
  def discover!(path) do
    {source_root, display_root} = roots!(path)

    source_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&discover_file(&1, display_root))
  end

  @doc "Parses one source file and inventories every directly declared module."
  @spec discover_file(Path.t(), Path.t()) :: file_inventory()
  def discover_file(path, display_root \\ File.cwd!()) do
    source = File.read!(path)
    relative_path = Path.relative_to(path, display_root)

    base = %{
      path: relative_path,
      digest: digest(source),
      modules: [],
      top_level_unsupported: []
    }

    case Code.string_to_quoted(source, file: path, columns: true) do
      {:ok, ast} -> inventory_ast(ast, base)
      {:error, error} -> Map.merge(base, %{status: :parse_error, parse_error: parse_error(error)})
    end
  end

  defp roots!(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(Path.join(expanded, "lib")) -> {Path.join(expanded, "lib"), expanded}
      File.dir?(expanded) -> {expanded, expanded}
      true -> raise ArgumentError, "Jason source directory does not exist: #{expanded}"
    end
  end

  defp inventory_ast(ast, base) do
    {modules, unsupported} =
      ast
      |> forms()
      |> Enum.reduce({[], []}, fn
        {:defmodule, _, _} = module_ast, {modules, unsupported} ->
          {modules ++ inventory_module_tree(module_ast, nil), unsupported}

        form, {modules, unsupported} ->
          {modules, unsupported ++ [unsupported_form(form, :unknown_form)]}
      end)

    Map.merge(base, %{
      status: :parsed,
      modules: modules,
      top_level_unsupported: unsupported
    })
  end

  defp inventory_module_tree({:defmodule, _, [name_ast, [do: body]]} = ast, parent) do
    module_name = declared_module(name_ast, parent)
    snapshot = Frontend.from_ast(ast)
    body_forms = forms(body)

    current = %{
      module: inspect(module_name),
      definitions: accepted_definitions(snapshot),
      unsupported: unsupported_forms(body_forms, snapshot.unsupported)
    }

    nested =
      body_forms
      |> Enum.flat_map(fn
        {:defmodule, _, _} = nested_ast -> inventory_module_tree(nested_ast, module_name)
        _ -> []
      end)

    [current | nested]
  end

  defp definition(%Frontend.Definition{} = definition) do
    %{
      kind: definition.kind,
      name: definition.name,
      arity: definition.arity,
      clauses: length(definition.clauses)
    }
  end

  # A guarded definition currently matches Frontend's broad `{name, _, args}`
  # head and is normalized as a function named `when`. Keep the inventory
  # faithful to the accepted snapshot while calling out that false acceptance
  # as a blocker instead of reporting misleading compiler coverage.
  defp accepted_definitions(snapshot) do
    snapshot.definitions
    |> Enum.reject(&(&1.name == :when))
    |> Enum.map(&definition/1)
  end

  defp unsupported_forms(forms, frontend_unsupported) do
    frontend_reasons = Map.new(frontend_unsupported, &{&1.form, &1.reason})

    forms
    |> Enum.reject(&simple_definition?/1)
    |> Enum.map(fn form ->
      unsupported_form(form, Map.get(frontend_reasons, form, :accepted_as_definition))
    end)
  end

  defp simple_definition?({kind, _, [{name, _, args}, [do: _body]]})
       when kind in [:def, :defp] and is_atom(name) and name != :when and is_list(args),
       do: true

  defp simple_definition?(_form), do: false

  defp unsupported_form(form, frontend_reason) do
    %{
      reason: classify(form, frontend_reason),
      frontend_reason: frontend_reason,
      line: line(form),
      form: summarize(form)
    }
  end

  defp classify({:@, _, _}, _), do: :module_attribute
  defp classify({kind, _, _}, _) when kind in [:import, :require, :use, :alias], do: kind
  defp classify({kind, _, _}, _) when kind in [:defmacro, :defmacrop], do: kind
  defp classify({kind, _, _}, _) when kind in [:defprotocol, :defimpl], do: kind

  defp classify({kind, _, [{:when, _, _} | _]}, _) when kind in [:def, :defp],
    do: :guarded_definition

  defp classify({:defmodule, _, _}, _), do: :nested_defmodule
  defp classify(_form, frontend_reason), do: frontend_reason

  defp declared_module({:__aliases__, _, parts}, nil), do: Module.concat(parts)

  defp declared_module({:__aliases__, _, [part]}, parent) when not is_nil(parent) do
    Module.concat(parent, part)
  end

  defp declared_module({:__aliases__, _, parts}, _parent), do: Module.concat(parts)
  defp declared_module(name, _parent) when is_atom(name), do: name

  defp forms({:__block__, _, forms}), do: forms
  defp forms(form), do: [form]

  defp line({_name, metadata, _args}) when is_list(metadata), do: metadata[:line]
  defp line(_form), do: nil

  defp summarize(form) do
    form
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> truncate(240)
  end

  defp truncate(value, limit) when byte_size(value) <= limit, do: value
  defp truncate(value, limit), do: binary_part(value, 0, limit) <> "..."

  defp parse_error({location, description, token}) do
    %{location: inspect(location), description: to_string(description), token: to_string(token)}
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
