defmodule Batata.Probe.CorpusCompileLink do
  @moduledoc """
  Diagnoses a corpus after shared, multi-source frontend normalization.

  Isolated module attempts remain diagnostic evidence, but the reported status
  comes only from a qualified, dependency-aware compilation unit containing
  every normalized module. Isolated success can never produce a corpus pass.
  """

  alias Batata.CompilationUnit
  alias Batata.Frontend
  alias Batata.Lower
  alias Batata.Probe.Jason.CompileAttempt
  alias Beaver.MLIR

  @mode "qualified_multi_module_unit"

  @spec run(Path.t()) :: map()
  def run(source) do
    sources = source |> source_files() |> Enum.map(&File.read!/1)
    modules = Frontend.from_sources(sources)
    module_names = MapSet.new(modules, & &1.name)
    dependencies = internal_dependencies(modules, module_names)
    attempts = Enum.map(modules, &attempt/1)
    isolated_passes = Enum.count(attempts, &(&1["status"] == "pass"))
    unit_attempt = attempt_unit(modules)
    status = if unit_attempt["status"] == "pass", do: "pass", else: "blocked"

    %{
      "status" => status,
      "mode" => @mode,
      "modules" => length(modules),
      "isolated_passes" => isolated_passes,
      "internal_dependencies" => dependencies,
      "unresolved_internal_dependencies" =>
        if(status == "pass", do: 0, else: length(dependencies)),
      "attempts" => attempts,
      "unit_attempt" => unit_attempt,
      "reason" => reason(unit_attempt)
    }
  rescue
    error ->
      Map.merge(
        %{
          "status" => "blocked",
          "mode" => @mode,
          "modules" => 0,
          "isolated_passes" => 0,
          "internal_dependencies" => [],
          "unresolved_internal_dependencies" => 0,
          "attempts" => [],
          "reason" => "shared_frontend_normalization_failed"
        },
        CompileAttempt.failure_details(error)
      )
  end

  defp source_files(source) do
    root = if File.dir?(Path.join(source, "lib")), do: Path.join(source, "lib"), else: source
    root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  defp attempt(module) do
    ctx = MLIR.Context.create()

    try do
      compiled = Batata.compile(module, ctx)

      try do
        compiled |> Lower.to_llvm(ctx) |> MLIR.verify!()
        %{"module" => inspect(module.name), "status" => "pass"}
      after
        MLIR.Module.destroy(compiled)
      end
    rescue
      error ->
        Map.merge(
          %{"module" => inspect(module.name), "status" => failure_status(error)},
          error_details(error)
        )
    after
      MLIR.Context.destroy(ctx)
    end
  end

  defp attempt_unit(modules) do
    modules
    |> CompilationUnit.build()
    |> attempt()
    |> Map.delete("module")
  end

  defp failure_status(%Batata.Lift.Error{}), do: "frontend_normalization_failure"
  defp failure_status(%Batata.Lower.Error{}), do: "lowering_failure"
  defp failure_status(_error), do: "ir_verification_failure"

  defp error_details(error) do
    error
    |> CompileAttempt.failure_details()
    |> Map.put("diagnostic", normalize_diagnostic(Exception.message(error)))
  end

  defp normalize_diagnostic(message) do
    message
    |> String.replace(~r/(?<![\w.])(?:[A-Za-z]:)?\/(?:[\w.\-]+\/)+[\w.\-]+/, "<path>")
    |> String.replace(~r/:(?:line\s*)?\d+(?::\d+)?/i, ":<location>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 512)
  end

  defp internal_dependencies(modules, module_names) do
    modules
    |> Enum.flat_map(fn module ->
      module.definitions
      |> Enum.flat_map(&definition_dependencies(&1, module.name, module_names))
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["caller"], &1["callee"], &1["function"], &1["arity"]})
  end

  defp definition_dependencies(definition, caller, module_names) do
    Enum.flat_map(definition.clauses, fn clause ->
      [clause.guard_ast, clause.body_ast]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&ast_dependencies(&1, caller, module_names))
    end)
  end

  defp ast_dependencies(ast, caller, module_names) do
    {_ast, dependencies} =
      Macro.prewalk(ast, [], fn
        {{:., _, [callee_ast, function]}, _, arguments} = node, dependencies
        when is_atom(function) and is_list(arguments) ->
          callee = module_name(callee_ast)

          if callee && MapSet.member?(module_names, callee) do
            dependency = %{
              "caller" => inspect(caller),
              "callee" => inspect(callee),
              "function" => Atom.to_string(function),
              "arity" => length(arguments)
            }

            {node, [dependency | dependencies]}
          else
            {node, dependencies}
          end

        node, dependencies ->
          {node, dependencies}
      end)

    dependencies
  end

  defp module_name(module) when is_atom(module), do: module

  defp module_name({:__aliases__, _, parts}) when is_list(parts) do
    Module.concat(parts)
  end

  defp module_name(_ast), do: nil

  defp reason(%{"status" => "pass"}), do: nil
  defp reason(%{"reason_class" => reason}), do: reason
  defp reason(_attempt), do: "compile_link_failed"
end
