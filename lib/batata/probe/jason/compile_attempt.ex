defmodule Batata.Probe.Jason.CompileAttempt do
  @moduledoc """
  Runs deterministic, non-executing compile attempts for structurally eligible
  corpus modules.

  The lane is deliberately module-scoped because Batata assigns closure and
  dispatch identities across a complete module. It compiles and lowers IR but
  never loads or executes the resulting module.
  """

  alias Batata.Lower
  alias Beaver.MLIR

  @statuses ~w(
    blocked_by_module_forms
    frontend_normalization_failure
    ir_verification_failure
    lowering_failure
    pass
  )

  @spec run([map()]) :: [map()]
  def run(files) do
    files
    |> Enum.flat_map(fn file ->
      Enum.map(file.modules, &attempt(file.path, &1))
    end)
    |> Enum.sort_by(&{&1["path"], &1["module"]})
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  @spec run_source(String.t(), String.t(), String.t()) :: map()
  def run_source(path, module_name, source) do
    ctx = MLIR.Context.create()

    try do
      case compile(source, ctx) do
        {:ok, compiled} -> lower(path, module_name, compiled, ctx)
        {:error, stage, error} -> failure(path, module_name, stage, error)
      end
    after
      MLIR.Context.destroy(ctx)
    end
  end

  @doc false
  @spec failure_details(Exception.t()) :: map()
  def failure_details(error) do
    message = Exception.message(error)
    reason_class = reason_class(error, message)
    normalized_message = normalize_message(message)

    %{
      "error" => error.__struct__ |> inspect(),
      "reason_class" => reason_class,
      "fingerprint" => digest(reason_class <> "\0" <> normalized_message)
    }
  end

  defp attempt(path, %{compile_source: nil} = module) do
    reasons =
      module.unsupported
      |> Enum.reject(&(&1.reason == :ignored_metadata))
      |> Enum.frequencies_by(&to_string(&1.reason))

    %{
      "path" => path,
      "module" => module.module,
      "status" => "blocked_by_module_forms",
      "blocker_categories" => reasons
    }
  end

  defp attempt(path, module) do
    run_source(path, module.module, module.compile_source)
  end

  defp compile(source, ctx) do
    {:ok, Batata.compile(source, ctx)}
  rescue
    error in Batata.Lift.Error -> {:error, "frontend_normalization_failure", error}
    error -> {:error, "ir_verification_failure", error}
  end

  defp lower(path, module_name, compiled, ctx) do
    compiled
    |> Lower.to_llvm(ctx)
    |> MLIR.verify!()

    %{"path" => path, "module" => module_name, "status" => "pass"}
  rescue
    error -> failure(path, module_name, "lowering_failure", error)
  end

  defp failure(path, module_name, status, error) do
    Map.merge(
      %{
        "path" => path,
        "module" => module_name,
        "status" => status
      },
      failure_details(error)
    )
  end

  defp reason_class(%Batata.Lift.Error{}, message) do
    if String.contains?(message, "a guarded function requires a following fallback clause") do
      "guarded_definition"
    else
      lift_reason_class(message)
    end
  end

  defp reason_class(%Batata.Lower.Error{}, message) do
    if String.contains?(message, "does not reference a valid function") do
      unresolved_call_class(message)
    else
      "lowering_pass_failure"
    end
  end

  defp reason_class(error, _message) do
    error.__struct__
    |> inspect()
    |> Macro.underscore()
  end

  defp lift_reason_class("dynamic_apply_without_local_dispatch" <> _message),
    do: "dynamic_apply_without_local_dispatch"

  defp lift_reason_class("multi-clause trailing arguments must be variables" <> _message),
    do: "multi_clause_trailing_literal_pattern"

  defp lift_reason_class(message) do
    cond do
      map_pattern?(message) ->
        "map_pattern"

      String.starts_with?(message, "unsupported parameter pattern: {:\\") ->
        "default_argument_pattern"

      String.contains?(message, "requires a final catch-all clause") ->
        "non_exhaustive_clauses"

      remote_module_call?(message) ->
        "remote_module_call"

      String.starts_with?(message, "unsupported stdlib call:") ->
        "unsupported_stdlib_call"

      String.starts_with?(message, "unsupported AST in the current slice:") ->
        "unsupported_ast"

      String.contains?(message, "interpolation") ->
        "string_interpolation"

      true ->
        "lift_error"
    end
  end

  defp unresolved_call_class(message) do
    cond do
      String.contains?(message, "@\"&&\"") -> "unresolved_short_circuit_and"
      String.contains?(message, "@\"<>\"") -> "unresolved_binary_concat"
      String.contains?(message, "@__aliases__") -> "unresolved_struct_constructor"
      String.contains?(message, "@if") -> "unresolved_if"
      true -> "lowering_pass_failure"
    end
  end

  defp map_pattern?(message) do
    (String.starts_with?(message, "unsupported parameter pattern:") or
       String.starts_with?(message, "unsupported case pattern:")) and
      String.contains?(message, "{:%{}")
  end

  defp remote_module_call?(message) do
    Regex.match?(~r/unsupported AST in the current slice: [A-Z][\w.]*\.[a-z_?!]+/u, message) or
      (String.starts_with?(message, "unsupported AST in the current slice: {:__aliases__") and
         Regex.match?(~r/\}\.[a-z_?!]+/u, message))
  end

  defp normalize_message(message) do
    message
    |> String.replace(~r/(?<![\w.])(?:[A-Za-z]:)?\/(?:[\w.\-]+\/)+[\w.\-]+/, "<path>")
    |> String.replace(~r/:(?:line\s*)?\d+(?::\d+)?/i, ":<location>")
    |> String.replace(~r/#PID<[^>]+>/, "#PID<...>")
    |> String.replace(~r/#Reference<[^>]+>/, "#Reference<...>")
    |> String.replace(~r/0x[0-9a-f]+/i, "0x...")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
