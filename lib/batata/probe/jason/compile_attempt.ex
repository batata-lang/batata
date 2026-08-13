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
    ctx = MLIR.Context.create()

    try do
      case compile(module.compile_source, ctx) do
        {:ok, compiled} -> lower(path, module.module, compiled, ctx)
        {:error, stage, error} -> failure(path, module.module, stage, error)
      end
    after
      MLIR.Context.destroy(ctx)
    end
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
    %{
      "path" => path,
      "module" => module_name,
      "status" => status,
      "error" => error.__struct__ |> inspect()
    }
  end
end
