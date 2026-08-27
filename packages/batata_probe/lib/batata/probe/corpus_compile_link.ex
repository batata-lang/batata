defmodule Batata.Probe.CorpusCompileLink do
  @moduledoc """
  Diagnoses a corpus after shared, multi-source frontend normalization.

  Isolated module attempts remain diagnostic evidence, but the reported status
  comes only from a qualified, dependency-aware compilation unit containing
  every normalized module. Isolated success can never produce a corpus pass.

  Isolated attempts may use bounded concurrency because each one owns its MLIR
  context. The qualified whole-corpus attempt always remains singular.
  """

  alias Batata.CompilationUnit
  alias Batata.Frontend
  alias Batata.Lower
  alias Batata.Probe.CompileAttempt
  alias Batata.Probe.CorpusRuntimeSlice
  alias Beaver.MLIR

  @mode "qualified_multi_module_unit"

  @spec run(Path.t(), keyword()) :: map()
  def run(source, opts \\ []) do
    max_concurrency = max_concurrency!(opts)
    diagnose_isolated? = diagnose_isolated!(opts)
    profile_output = profile_output!(opts)
    do_run(source, max_concurrency, diagnose_isolated?, profile_output)
  end

  defp do_run(source, max_concurrency, diagnose_isolated?, profile_output) do
    sources = source |> source_files() |> Enum.map(&File.read!/1)
    modules = Frontend.from_sources(sources)
    runtime_slice = CorpusRuntimeSlice.slice(source, modules)
    runtime_modules = runtime_slice.modules
    module_names = MapSet.new(runtime_modules, & &1.name)
    dependencies = internal_dependencies(runtime_modules, module_names)
    attempts = if diagnose_isolated?, do: isolated_attempts(modules, max_concurrency), else: []
    isolated_passes = Enum.count(attempts, &(&1["status"] == "pass"))

    {unit_attempt, profile} =
      if profile_output do
        attempt_unit_profiled(runtime_modules)
      else
        {attempt_unit(runtime_modules), nil}
      end

    maybe_write_profile!(profile_output, profile)
    status = if unit_attempt["status"] == "pass", do: "pass", else: "blocked"

    %{
      "status" => status,
      "mode" => @mode,
      "modules" => length(modules),
      "isolated_attempts" => if(diagnose_isolated?, do: "executed", else: "omitted"),
      "runtime_slice" => %{
        "removed_definitions" => runtime_slice.removed_definitions,
        "removed_definition_count" => length(runtime_slice.removed_definitions)
      },
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

  defp max_concurrency!(opts) do
    case Keyword.get(opts, :max_concurrency, 1) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError, "max_concurrency must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp diagnose_isolated!(opts) do
    case Keyword.get(opts, :diagnose_isolated, true) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, "diagnose_isolated must be a boolean, got: #{inspect(value)}"
    end
  end

  defp profile_output!(opts) do
    case Keyword.get(opts, :profile_output) do
      nil -> nil
      value when is_binary(value) -> value
      value -> raise ArgumentError, "profile_output must be a path, got: #{inspect(value)}"
    end
  end

  defp isolated_attempts(modules, 1), do: Enum.map(modules, &attempt/1)

  # Every task owns an independent MLIR context. The qualified whole-corpus
  # attempt remains outside this pool so the largest compilation is never
  # multiplied by this option.
  defp isolated_attempts(modules, max_concurrency) do
    modules
    |> Task.async_stream(&attempt/1,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
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
        destroy_module(compiled)
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

  defp attempt_unit_profiled(modules) do
    modules
    |> CompilationUnit.build()
    |> attempt_profiled()
    |> then(fn {attempt, profile} -> {Map.delete(attempt, "module"), profile} end)
  end

  defp attempt_profiled(module) do
    ctx = MLIR.Context.create()
    total_started = measurement_start()

    try do
      compile_started = measurement_start()
      {compile_outcome, compile_receipt} = Batata.profile_compile(module, ctx)

      compile_stage =
        measurement_finish(compile_started, outcome_status(compile_outcome), "compile")
        |> Map.put("compilation", compile_receipt)

      case compile_outcome do
        {:ok, compiled} ->
          {attempt, stages} = profile_compiled(module, compiled, ctx, compile_stage)

          {_cleanup_outcome, cleanup_stage} =
            measure_stage("cleanup", fn -> destroy_module(compiled) end)

          {attempt, profile_receipt(attempt, total_started, stages ++ [cleanup_stage])}

        {:error, _kind, error, _stacktrace} ->
          attempt = failure_attempt(module, error)
          {attempt, profile_receipt(attempt, total_started, [compile_stage])}
      end
    after
      MLIR.Context.destroy(ctx)
    end
  end

  defp profile_compiled(module, compiled, ctx, compile_stage) do
    lower_started = measurement_start()
    {lower_outcome, lower_receipt} = Lower.profile_to_llvm(compiled, ctx)

    lower_stage =
      measurement_finish(lower_started, outcome_status(lower_outcome), "lower")
      |> Map.put("lowering", lower_receipt)

    case lower_outcome do
      {:ok, lowered} ->
        {verify_outcome, verify_stage} = measure_stage("verify", fn -> MLIR.verify!(lowered) end)

        attempt =
          case verify_outcome do
            {:ok, _verified} -> %{"module" => inspect(module.name), "status" => "pass"}
            {:error, _kind, error, _stacktrace} -> failure_attempt(module, error)
          end

        {attempt, [compile_stage, lower_stage, verify_stage]}

      {:error, _kind, error, _stacktrace} ->
        attempt = failure_attempt(module, error)
        {attempt, [compile_stage, lower_stage]}
    end
  end

  defp failure_attempt(module, error) do
    Map.merge(
      %{"module" => inspect(module.name), "status" => failure_status(error)},
      error_details(error)
    )
  end

  defp profile_receipt(attempt, started, stages) do
    measurement_finish(started, attempt_status(attempt), "qualified_multi_module_unit")
    |> Map.merge(%{
      "schema_version" => 1,
      "outcome" => Map.take(attempt, ["status", "reason_class", "fingerprint", "error"]),
      "stages" => stages
    })
  end

  defp measure_stage(name, callback) do
    started = measurement_start()

    outcome =
      try do
        {:ok, callback.()}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end

    {outcome, measurement_finish(started, outcome_status(outcome), name)}
  end

  defp measurement_start do
    %{
      monotonic_ns: System.monotonic_time(:nanosecond),
      process_cpu_time_ns: MLIR.CAPI.beaver_raw_process_cpu_time(),
      peak_rss_bytes: MLIR.CAPI.beaver_raw_peak_rss(),
      reductions: reductions(),
      process_memory_bytes: process_memory_bytes()
    }
  end

  defp measurement_finish(started, status, name) do
    process_memory_after_bytes = process_memory_bytes()
    peak_rss_after_bytes = MLIR.CAPI.beaver_raw_peak_rss()

    %{
      "name" => name,
      "status" => status,
      "duration_ns" => max(System.monotonic_time(:nanosecond) - started.monotonic_ns, 0),
      "process_cpu_time_ns" =>
        max(MLIR.CAPI.beaver_raw_process_cpu_time() - started.process_cpu_time_ns, 0),
      "rss" => %{
        "peak_before_bytes" => started.peak_rss_bytes,
        "peak_after_bytes" => peak_rss_after_bytes,
        "peak_delta_bytes" => max(peak_rss_after_bytes - started.peak_rss_bytes, 0)
      },
      "beam" => %{
        "reductions" => max(reductions() - started.reductions, 0),
        "process_memory_before_bytes" => started.process_memory_bytes,
        "process_memory_after_bytes" => process_memory_after_bytes
      }
    }
  end

  defp maybe_write_profile!(nil, _profile), do: :ok

  defp maybe_write_profile!(output, profile) do
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, JSON.encode!(profile))
  end

  defp outcome_status({:ok, _result}), do: "ok"
  defp outcome_status({:error, _kind, _reason, _stacktrace}), do: "error"
  defp attempt_status(%{"status" => "pass"}), do: "ok"
  defp attempt_status(_attempt), do: "error"

  defp reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end

  defp process_memory_bytes do
    {:memory, memory} = Process.info(self(), :memory)
    memory
  end

  defp destroy_module(module) do
    module
    |> MLIR.Operation.from_module()
    |> MLIR.CAPI.beaverOperationDestroyIterative_dirty_cpu()
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
