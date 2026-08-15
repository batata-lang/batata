defmodule Batata.Probe.Jason.GenerationAttempt do
  @moduledoc """
  Runs isolated diagnostic attempts for bounded definition generation.

  The attempt deliberately does not change inventory eligibility. It selects a
  tightly bounded definition-generating blocker, expands only its generated
  `def`/`defp` forms, and runs those definitions through Batata in a synthetic
  module. All other module forms are reported as removed scope rather than
  silently counted as coverage.
  """

  alias Batata.Probe.Jason.{BlockerIdentity, CompileAttempt}

  @for_root "for/2"
  @if_root "if/2"
  @definition_kinds [:def, :defp]
  @forbidden_nested [:fn, :quote]

  @doc "Runs deterministic generation diagnostics for eligible blockers."
  @spec run([map()]) :: [map()]
  def run(files) do
    files
    |> Enum.flat_map(fn file ->
      Enum.flat_map(file.modules, &attempts(file.path, &1))
    end)
    |> Enum.sort_by(&{&1["path"], &1["module"], &1["line"], &1["blocker_id"]})
  end

  @doc false
  @spec expand_candidate(map(), String.t()) :: {:ok, map()} | :error
  def expand_candidate(unsupported, module_name) do
    with true <- candidate?(unsupported),
         {:ok, generation_root, expanded} <- expand_form(unsupported) do
      {:ok,
       %{
         source: synthetic_source(module_name, expanded),
         expanded_definition_count: length(expanded),
         generation_root: generation_root
       }}
    else
      _ -> :error
    end
  end

  defp attempts(path, module) do
    Enum.flat_map(module.unsupported, fn unsupported ->
      case expand_candidate(unsupported, module.module) do
        {:ok, expansion} -> [run_attempt(path, module, unsupported, expansion)]
        :error -> []
      end
    end)
  end

  defp run_attempt(path, module, unsupported, expansion) do
    result = CompileAttempt.run_source(path, module.module, expansion.source)
    status = result["status"]

    result
    |> Map.drop(["path", "module", "status"])
    |> Map.merge(%{
      "path" => path,
      "module" => module.module,
      "line" => unsupported.line,
      "blocker_id" => BlockerIdentity.id(path, module.module, unsupported),
      "generation_root" => expansion.generation_root,
      "diagnostic_only" => true,
      "outcome" => "reached_compile_pipeline",
      "compile_phase" => compile_phase(status),
      "phase" => attempt_phase(status),
      "expanded_definition_count" => expansion.expanded_definition_count,
      "removed_scope" => %{
        "accepted_definitions" => length(module.definitions),
        "unsupported_forms" => length(module.unsupported) - 1
      }
    })
  end

  defp candidate?(unsupported) do
    unsupported.reason == :module_level_generation and
      Map.get(unsupported, :generation_construct) == :definition_generation and
      Map.get(unsupported, :generation_root) in [@for_root, @if_root]
  end

  defp expand_form(%{generation_root: @for_root, form_ast: form}) do
    with {:ok, variable, values, definitions} <- bounded_for(form),
         :ok <- validate_definitions(definitions, variable) do
      expanded =
        for value <- values,
            definition <- definitions,
            do: substitute(definition, variable, value)

      {:ok, @for_root, expanded}
    end
  end

  defp expand_form(%{generation_root: @if_root, form_ast: form}) do
    with {:ok, definitions} <- bounded_version_if(form) do
      {:ok, @if_root, definitions}
    end
  end

  defp expand_form(_unsupported), do: :error

  defp bounded_for({:for, _, [{:<-, _, [{variable, _, context}, values]}, options]})
       when is_atom(variable) and (is_atom(context) or is_nil(context)) and is_list(values) and
              is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, body} <- Keyword.fetch(options, :do),
         true <- options |> Keyword.delete(:do) |> Enum.empty?(),
         true <- values != [] and Enum.all?(values, &bounded_literal?/1),
         {:ok, definitions} <- definition_forms(body) do
      {:ok, variable, values, definitions}
    else
      _ -> :error
    end
  end

  defp bounded_for(_form), do: :error

  defp bounded_version_if(
         {:if, _,
          [
            {:==, _,
             [
               {{:., _, [{:__aliases__, _, [:Version]}, :compare]}, _,
                [
                  {{:., _, [{:__aliases__, _, [:System]}, :version]}, _, []},
                  version_literal
                ]},
               :lt
             ]},
            options
          ]}
       )
       when is_binary(version_literal) and is_list(options) do
    system_version = System.version()

    with true <- exact_if_options?(options),
         {:ok, _system_version} <- Version.parse(system_version),
         {:ok, _version_literal} <- Version.parse(version_literal),
         {:ok, then_definitions} <- options |> Keyword.fetch!(:do) |> definition_forms(),
         {:ok, else_definitions} <- options |> Keyword.fetch!(:else) |> definition_forms(),
         :ok <- validate_definitions(then_definitions, nil),
         :ok <- validate_definitions(else_definitions, nil) do
      selected =
        if Version.compare(system_version, version_literal) == :lt,
          do: then_definitions,
          else: else_definitions

      {:ok, selected}
    else
      _ -> :error
    end
  end

  defp bounded_version_if(_form), do: :error

  defp exact_if_options?(options) do
    Keyword.keyword?(options) and length(options) == 2 and
      Enum.sort(Keyword.keys(options)) == Enum.sort([:do, :else])
  end

  defp definition_forms({:__block__, _, forms}) when is_list(forms),
    do: definition_forms(forms)

  defp definition_forms(forms) when is_list(forms) do
    if forms != [] and Enum.all?(forms, &definition?/1), do: {:ok, forms}, else: :error
  end

  defp definition_forms(form) do
    if definition?(form), do: {:ok, [form]}, else: :error
  end

  defp definition?({kind, _, [_head, body]}) when kind in @definition_kinds and is_list(body),
    do: Keyword.keyword?(body) and Keyword.has_key?(body, :do)

  defp definition?(_form), do: false

  defp validate_definitions(definitions, variable) do
    if Enum.all?(definitions, &valid_node?(&1, variable)), do: :ok, else: :error
  end

  defp valid_node?({:unquote, _, [{variable, _, context}]}, variable)
       when not is_nil(variable) and (is_atom(context) or is_nil(context)),
       do: true

  defp valid_node?({:unquote, _, _args}, nil), do: false
  defp valid_node?({:unquote, _, _args}, _variable), do: false
  defp valid_node?({kind, _, _args}, _variable) when kind in @forbidden_nested, do: false

  defp valid_node?({variable, metadata, context}, variable)
       when not is_nil(variable) and is_list(metadata) and
              (is_atom(context) or is_nil(context)),
       do: false

  defp valid_node?(node, variable) when is_tuple(node) do
    node |> Tuple.to_list() |> Enum.all?(&valid_node?(&1, variable))
  end

  defp valid_node?(node, variable) when is_list(node),
    do: Enum.all?(node, &valid_node?(&1, variable))

  defp valid_node?(_node, _variable), do: true

  defp substitute(definition, variable, value) do
    Macro.prewalk(definition, fn
      {:unquote, _, [{^variable, _, context}]} when is_atom(context) or is_nil(context) -> value
      node -> node
    end)
  end

  defp bounded_literal?(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp bounded_literal?({:__aliases__, _, parts}) when is_list(parts),
    do: parts != [] and Enum.all?(parts, &is_atom/1)

  defp bounded_literal?(_value), do: false

  defp synthetic_source(module_name, definitions) do
    module = module_name |> String.split(".") |> Module.concat()
    body = definitions ++ [quote(do: def(main, do: 0))]

    {:defmodule, [], [module, [do: {:__block__, [], body}]]}
    |> Macro.to_string()
  end

  defp compile_phase(status) when status in ["lowering_failure", "pass"], do: "pass"
  defp compile_phase(status), do: status

  defp attempt_phase("pass"), do: "lowering_complete"
  defp attempt_phase(status), do: status
end
