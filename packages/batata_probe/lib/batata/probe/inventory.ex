defmodule Batata.Probe.Inventory do
  @moduledoc """
  Discovers the frontend surface of a pinned Elixir source tree.

  The inventory deliberately parses source without expanding macros. It uses
  `Batata.Frontend` for the same module-boundary classification as the compiler
  and augments each unsupported form with a stable, more specific probe reason.
  This makes early frontend failures inspectable without pretending that the
  source compiled further into the pipeline.
  """

  alias Batata.Frontend
  alias Batata.Frontend.AliasExpand
  alias Batata.Frontend.DefaultArgExpand
  alias Batata.Frontend.GuardSupport
  alias Batata.Probe.CallPhase
  alias Batata.Probe.DiagnosticSlice

  @ignored_metadata_attributes [
    :doc,
    :moduledoc,
    :spec,
    :type,
    :typep,
    :opaque,
    :typedoc,
    :deprecated,
    :behaviour
  ]

  @compile_annotation_attributes [:compile, :dialyzer, :impl]
  @compile_time_eval_attributes [:digits, :power_of_2_to_52]
  @module_generation_forms [:for, :if, :unless, :case, :cond, :try, :with]
  @definition_generation_forms [
    :def,
    :defp,
    :defmacro,
    :defmacrop,
    :defmodule,
    :defimpl,
    :defprotocol
  ]

  @type unsupported :: %{
          required(:reason) => atom(),
          required(:frontend_reason) => atom(),
          required(:line) => non_neg_integer() | nil,
          required(:form) => String.t(),
          optional(:generation_construct) => atom(),
          optional(:generation_root) => String.t()
        }

  @type module_inventory :: %{
          required(:module) => String.t(),
          required(:definitions) => [map()],
          required(:unsupported) => [unsupported()],
          required(:dependency_forms) => [Macro.t()],
          required(:compile_harness) => map(),
          required(:diagnostic_source) => String.t() | nil,
          required(:compile_source) => String.t() | nil
        }

  @type file_inventory :: %{
          required(:path) => String.t(),
          required(:digest) => String.t(),
          required(:status) => :parsed | :parse_error,
          required(:modules) => [module_inventory()],
          required(:top_level_unsupported) => [map()],
          optional(:parse_error) => map()
        }

  @doc "Discovers every `.ex` file below an Elixir project or `lib` directory."
  @spec discover!(Path.t()) :: [file_inventory()]
  def discover!(path) do
    {source_root, display_root} = roots!(path)

    source_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&discover_file_raw(&1, display_root))
    |> put_diagnostic_sources()
  end

  @doc "Parses one source file and inventories every directly declared module."
  @spec discover_file(Path.t(), Path.t()) :: file_inventory()
  def discover_file(path, display_root \\ File.cwd!()) do
    path
    |> discover_file_raw(display_root)
    |> then(&put_diagnostic_sources([&1]))
    |> hd()
  end

  defp discover_file_raw(path, display_root) do
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
      true -> raise ArgumentError, "corpus source directory does not exist: #{expanded}"
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

  defp inventory_module_tree({:defmodule, _, [name_ast, [do: _body]]} = ast, parent) do
    module_name = declared_module(name_ast, parent)
    {:defmodule, _, [_name, [do: source_body]]} = ast
    source_snapshot = Frontend.from_expanded_ast(ast)
    expanded_ast = ast |> AliasExpand.expand() |> DefaultArgExpand.expand()
    {:defmodule, _, [_name, [do: expanded_body]]} = expanded_ast
    source_forms = forms(source_body)
    expanded_forms = forms(expanded_body)

    unsupported =
      source_forms
      |> unsupported_forms(source_snapshot.unsupported)
      |> Enum.reject(fn unsupported ->
        supported_alias?(unsupported) or
          supported_guarded_definition?(unsupported) or
          supported_current_module_schema?(
            unsupported,
            source_snapshot,
            module_name,
            :exception
          ) or
          supported_current_module_schema?(
            unsupported,
            source_snapshot,
            module_name,
            :struct
          )
      end)

    current = %{
      module: inspect(module_name),
      definitions: accepted_definitions(source_snapshot),
      unsupported: unsupported,
      dependency_forms: dependency_forms(expanded_forms),
      diagnostic_source: nil,
      compile_harness: harness_details(expanded_forms),
      compile_source: compile_source(module_name, expanded_forms, unsupported)
    }

    nested =
      source_forms
      |> Enum.flat_map(fn
        {:defmodule, _, _} = nested_ast -> inventory_module_tree(nested_ast, module_name)
        _ -> []
      end)

    [current | nested]
  end

  defp supported_alias?(%{reason: :alias, form_ast: form}),
    do: AliasExpand.supported_declaration?(form)

  defp supported_alias?(_unsupported), do: false

  # Probe-internal evidence predicate. A compiler lowering alone does not make
  # an inventory blocker eligible: require the canonical frontend acceptance
  # and exact guarded-definition source shape as well.
  @doc false
  @spec supported_guarded_definition?(map()) :: boolean()
  def supported_guarded_definition?(%{
        reason: :guarded_definition,
        frontend_reason: :accepted_as_definition,
        form_ast: {kind, _, [{:when, _, [{name, _, args}, guard_ast]}, [do: _body]]}
      })
      when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    GuardSupport.compiler_supported?(guard_ast)
  end

  def supported_guarded_definition?(_unsupported), do: false

  # Probe-internal evidence predicate. Inventory owns the only eligibility
  # call site; the production compiler does not consult probe classifications.
  @doc false
  @spec supported_current_module_schema?(
          map(),
          Frontend.Module.t(),
          module(),
          :struct | :exception
        ) ::
          boolean()
  def supported_current_module_schema?(
        %{reason: reason, frontend_reason: :accepted_as_definition, form_ast: {form_kind, _, _}},
        %Frontend.Module{
          struct_schema: %Frontend.StructSchema{module: module, kind: schema_kind}
        },
        module,
        schema_kind
      )
      when schema_kind in [:struct, :exception] do
    {reason, form_kind} == schema_evidence(schema_kind)
  end

  def supported_current_module_schema?(_unsupported, _snapshot, _module, _schema_kind),
    do: false

  defp schema_evidence(:struct), do: {:struct_semantics, :defstruct}
  defp schema_evidence(:exception), do: {:exception_semantics, :defexception}

  defp definition(%Frontend.Definition{} = definition) do
    %{
      kind: definition.kind,
      name: definition.name,
      arity: definition.arity,
      clauses: length(definition.clauses)
    }
  end

  defp accepted_definitions(snapshot) do
    snapshot.definitions
    |> Enum.reject(fn definition ->
      Enum.any?(definition.clauses, fn clause ->
        clause.guard_ast != nil and not GuardSupport.compiler_supported?(clause.guard_ast)
      end)
    end)
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

  defp simple_definition?({kind, _, [{:when, _, [{name, _, args}, guard_ast]}, [do: _body]]})
       when kind in [:def, :defp] and is_atom(name) and is_list(args),
       do: GuardSupport.supported?(guard_ast)

  defp simple_definition?(_form), do: false

  defp compile_source(module_name, body_forms, unsupported) do
    if Enum.all?(unsupported, &(&1.reason == :ignored_metadata)) do
      module_source(module_name, ensure_main(body_forms))
    end
  end

  defp module_source(module_name, body_forms) do
    {:defmodule, [], [module_name, [do: {:__block__, [], body_forms}]]}
    |> Macro.to_string()
  end

  defp harness_details(body_forms) do
    %{
      original_forms: true,
      scope: "target-module-body",
      synthetic_main: not Enum.any?(body_forms, &main_definition?/1)
    }
  end

  defp put_diagnostic_sources(files) do
    compile_time_only =
      files
      |> Enum.reduce(MapSet.new(), fn file, calls ->
        module_calls =
          file.modules
          |> Enum.flat_map(& &1.dependency_forms)
          |> CallPhase.collect()

        top_level_calls =
          file.top_level_unsupported
          |> Enum.map(& &1.form_ast)
          |> CallPhase.collect()

        calls
        |> MapSet.union(module_calls)
        |> MapSet.union(top_level_calls)
      end)
      |> CallPhase.compile_time_only()

    Enum.map(files, fn file ->
      modules =
        Enum.map(file.modules, fn module ->
          module_name = module.module |> String.split(".") |> Module.concat()
          signatures = Map.get(compile_time_only, module.module, MapSet.new())

          Map.put(
            module,
            :diagnostic_source,
            diagnostic_source(
              module_name,
              module.dependency_forms,
              module.unsupported,
              signatures
            )
          )
        end)

      Map.put(file, :modules, modules)
    end)
  end

  defp diagnostic_source(module_name, body_forms, unsupported, compile_time_public) do
    blockers = Enum.reject(unsupported, &(&1.reason == :ignored_metadata))

    cond do
      blockers != [] and
          Enum.all?(blockers, &(&1.reason in [:exception_semantics, :struct_semantics])) ->
        schema = Enum.filter(body_forms, &schema_declaration?/1)
        definitions = body_forms |> Enum.filter(&simple_definition?/1) |> ensure_main()
        module_source(module_name, schema ++ definitions)

      blockers != [] and Enum.all?(blockers, &(&1.reason == :macro_definition)) ->
        case DiagnosticSlice.ordinary_definitions(body_forms, compile_time_public) do
          [] -> nil
          definitions -> module_source(module_name, ensure_main(definitions))
        end

      true ->
        nil
    end
  end

  defp schema_declaration?({kind, _, _}) when kind in [:defstruct, :defexception], do: true
  defp schema_declaration?(_form), do: false

  defp dependency_forms(forms) do
    Enum.reject(forms, fn
      {:defmodule, _, _} -> true
      form -> classify(form, :unknown_form) == :ignored_metadata
    end)
  end

  defp ensure_main(definitions) do
    if Enum.any?(definitions, &main_definition?/1) do
      definitions
    else
      definitions ++ [quote(do: def(main, do: 0))]
    end
  end

  defp main_definition?({:def, _, [{:main, _, args}, [do: _body]]}) when args in [[], nil],
    do: true

  defp main_definition?(_form), do: false

  defp unsupported_form(form, frontend_reason) do
    entry = %{
      reason: classify(form, frontend_reason),
      frontend_reason: frontend_reason,
      line: line(form),
      form: summarize(form),
      form_ast: form
    }

    entry =
      if entry.reason == :module_level_generation do
        Map.merge(entry, %{
          generation_construct: generation_construct(form),
          generation_root: generation_root(form)
        })
      else
        entry
      end

    case module_attribute(form) do
      nil -> entry
      attribute -> Map.put(entry, :attribute, attribute)
    end
  end

  defp generation_construct(form) do
    cond do
      definition_generation?(form) -> :definition_generation
      match?({:=, _, _}, form) -> :module_match
      generator_control?(form) -> :generator_control
      module_call?(form) -> :module_call
      true -> :other
    end
  end

  defp definition_generation?(form) do
    {_form, found?} =
      Macro.prewalk(form, false, fn
        {kind, _, _} = node, _found? when kind in @definition_generation_forms ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp generator_control?({kind, _, _}) when kind in @module_generation_forms, do: true
  defp generator_control?(_form), do: false

  defp module_call?({{:., _, _}, _, args}) when is_list(args), do: true
  defp module_call?({name, _, args}) when is_atom(name) and is_list(args), do: true
  defp module_call?(_form), do: false

  defp generation_root({{:., _, [module, name]}, _, args})
       when is_atom(name) and is_list(args) do
    "#{Macro.to_string(module)}.#{name}/#{length(args)}"
  end

  defp generation_root({name, _, args}) when is_atom(name) and is_list(args) do
    "#{root_name(name)}/#{length(args)}"
  end

  defp generation_root(_form), do: "other"

  defp root_name(:=), do: "="
  defp root_name(name), do: to_string(name)

  defp classify({:@, _, [{attribute, _, _}]}, _)
       when attribute in @ignored_metadata_attributes,
       do: :ignored_metadata

  defp classify({:@, _, _} = form, _) do
    if ignored_compile_metadata?(form), do: :ignored_metadata, else: classify_attribute(form)
  end

  defp classify({kind, _, _}, _) when kind in [:import, :require, :use, :alias], do: kind
  defp classify({kind, _, _}, _) when kind in [:defmacro, :defmacrop], do: :macro_definition
  defp classify({kind, _, _}, _) when kind in [:defprotocol, :defimpl], do: kind

  defp classify({kind, _, [{:when, _, _} | _]}, _) when kind in [:def, :defp],
    do: :guarded_definition

  defp classify({:defmodule, _, _}, _), do: :nested_defmodule
  defp classify({:defstruct, _, _}, _), do: :struct_semantics
  defp classify({:defexception, _, _}, _), do: :exception_semantics
  defp classify({:defrecordp, _, _}, _), do: :record_semantics

  defp classify({kind, _, _}, _) when kind in @module_generation_forms,
    do: :module_level_generation

  defp classify({:=, _, _}, _), do: :module_level_generation
  defp classify({{:., _, _}, _, _}, _), do: :module_level_generation

  defp classify({name, _, args}, _) when is_atom(name) and is_list(args),
    do: :module_level_generation

  defp classify(_form, frontend_reason), do: frontend_reason

  defp classify_attribute({:@, _, [{attribute, _, _}]})
       when attribute in @compile_annotation_attributes,
       do: :compile_annotation

  defp classify_attribute({:@, _, [{attribute, _, _}]})
       when attribute in @compile_time_eval_attributes,
       do: :compile_time_eval_attribute

  defp classify_attribute({:@, _, _}), do: :semantic_module_attribute

  defp ignored_compile_metadata?({:@, _, [{:compile, _, [inline: entries]}]})
       when is_list(entries),
       do: Keyword.keyword?(entries)

  defp ignored_compile_metadata?({:@, _, [{:dialyzer, _, [:no_improper_lists]}]}), do: true
  defp ignored_compile_metadata?({:@, _, [{:impl, _, [true]}]}), do: true

  defp ignored_compile_metadata?({:@, _, [{:impl, _, [{:__aliases__, _, parts}]}]})
       when is_list(parts),
       do: Enum.all?(parts, &is_atom/1)

  defp ignored_compile_metadata?(_form), do: false

  defp module_attribute({:@, _, [{attribute, _, _}]}) when is_atom(attribute), do: attribute
  defp module_attribute(_form), do: nil

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
