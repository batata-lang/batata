defmodule Batata.Memory.Verifier do
  @moduledoc "Fail-closed policy boundary between verified `ex` IR and Lower."

  alias Batata.Memory
  alias Batata.Memory.{Analyzer, DiagnosticError, Plan}

  @doc "Runs M0 analysis when enabled and rejects residual obligations in strict mode."
  @spec verify!(Beaver.MLIR.Module.t(), keyword()) :: :disabled | Plan.t()
  def verify!(module, opts) when is_list(opts) do
    policy = opts |> Keyword.get(:policy, :disabled) |> Memory.validate_policy!()

    case policy do
      :disabled ->
        :disabled

      enabled ->
        module
        |> Analyzer.analyze(Keyword.put(opts, :policy, enabled))
        |> verify_plan!()
    end
  end

  @doc "Verifies a previously constructed memory plan."
  @spec verify_plan!(Plan.t()) :: Plan.t()
  def verify_plan!(%Plan{policy: :strict, obligations: [_ | _] = obligations}) do
    obstruction = Enum.min_by(obligations, &{&1.site.id, to_string(&1.kind)})

    raise diagnostic(obstruction, :strict)
  end

  def verify_plan!(%Plan{} = plan), do: plan

  @doc false
  @spec diagnostic(Batata.Memory.Obligation.t(), :report | :strict) :: DiagnosticError.t()
  def diagnostic(obstruction, policy) when policy in [:report, :strict] do
    DiagnosticError.exception(
      code: diagnostic_code(obstruction.kind),
      message: obstruction.missing_fact,
      policy: policy,
      site: obstruction.site,
      obstruction: obstruction,
      strategies: obstruction.strategies
    )
  end

  defp diagnostic_code(kind)
       when kind in [:external_summary_missing, :callee_summary_missing],
       do: "E_MEMORY_CALLEE_SUMMARY_MISSING"

  defp diagnostic_code(:allocation_bound_missing), do: "E_MEMORY_BOUND_MISSING"
  defp diagnostic_code(_kind), do: "E_MEMORY_EFFECT_UNKNOWN"
end
