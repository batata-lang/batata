defmodule Batata.Memory.Analyzer do
  @moduledoc """
  Builds the M0 allocation inventory from verified, transformed `ex` IR.

  Sites are structural equivalence classes, not traversal ordinals. Repeated
  identical operations share one stable site and record their multiplicity.
  This avoids inventing unstable identities while source locations are still
  absent from parts of Lift.
  """

  alias Batata.Memory
  alias Batata.Memory.{Effect, Inventory, Obligation, Plan, Site}
  alias Beaver.MLIR
  alias Beaver.Walker

  @native_lock_path Path.expand("../../../native-deps.lock", __DIR__)
  @external_resource @native_lock_path
  @native_lock_hash "sha256:" <>
                      (@native_lock_path
                       |> File.read!()
                       |> then(&:crypto.hash(:sha256, &1))
                       |> Base.encode16(case: :lower))

  @type operation_fact :: %{
          operation: String.t(),
          function: String.t(),
          arity: non_neg_integer(),
          signature: String.t(),
          callee: String.t() | nil,
          location: String.t()
        }

  @doc "Analyzes a verified `ex` module under `:report` or `:strict` policy."
  @spec analyze(MLIR.Module.t(), keyword()) :: Plan.t()
  def analyze(module, opts) when is_list(opts) do
    policy = opts |> Keyword.get(:policy, :report) |> Memory.validate_policy!()

    if policy == :disabled do
      raise ArgumentError, "Batata.Memory.analyze/2 requires :report or :strict policy"
    end

    module_name = Keyword.fetch!(opts, :module)
    source = Keyword.fetch!(opts, :source)
    local_symbols = local_symbols(module)

    {effects, obligations} =
      module
      |> operation_facts()
      |> Enum.group_by(&fact_identity/1)
      |> Enum.map(fn {_identity, facts} ->
        analyze_equivalence_class(facts, module_name, local_symbols)
      end)
      |> Enum.sort_by(fn {effect, _obligation} -> effect.site.id end)
      |> Enum.unzip()

    Plan.new!(
      policy: policy,
      source_hash: sha256(source_bytes(source)),
      compiler_version: compiler_version(),
      dependency_lock: dependency_lock(opts),
      effects: effects,
      obligations: Enum.reject(obligations, &is_nil/1)
    )
  end

  defp analyze_equivalence_class([fact | _] = facts, module_name, local_symbols) do
    inventory = Inventory.intrinsic(fact.operation)
    {provenance, callee_scope} = call_provenance(fact, inventory.provenance, local_symbols)

    site =
      Site.structural!(
        module: module_name,
        function: fact.function,
        arity: fact.arity,
        semantic_path: ["ir", fact.operation, "equivalence", Memory.digest(fact_identity(fact))],
        identity: fact_identity(fact),
        ir_location: fact.location
      )

    context = %{
      "callee_scope" => callee_scope,
      "multiplicity" => length(facts),
      "operation" => fact.operation
    }

    effect =
      Effect.new!(
        site: site,
        classification: inventory.classification,
        provenance: provenance,
        callee: fact.callee,
        context: context
      )

    {effect, obligation(effect)}
  end

  defp obligation(%Effect{classification: :none}), do: nil

  defp obligation(%Effect{classification: :may_allocate} = effect) do
    Obligation.new!(
      kind: :allocation_bound_missing,
      site: effect.site,
      missing_fact: "a closed size, region, escape, and lifetime bound",
      context: effect.context,
      strategies: [
        %{
          "action" => "declare-allocation-summary",
          "operation" => effect.context["operation"]
        }
      ]
    )
  end

  defp obligation(%Effect{classification: :unknown, callee: callee} = effect)
       when is_binary(callee) do
    external? = effect.context["callee_scope"] == "external"

    Obligation.new!(
      kind: if(external?, do: :external_summary_missing, else: :callee_summary_missing),
      site: effect.site,
      missing_fact: "a closed allocation summary for callee #{callee}",
      context: effect.context,
      strategies: [
        %{
          "action" =>
            if(external?, do: "declare-external-summary", else: "derive-callee-summary"),
          "callee" => callee
        }
      ]
    )
  end

  defp obligation(%Effect{classification: :unknown} = effect) do
    Obligation.new!(
      kind: :allocation_effect_unknown,
      site: effect.site,
      missing_fact: "an explicit allocation effect for #{effect.context["operation"]}",
      context: effect.context,
      strategies: [
        %{
          "action" => "classify-intrinsic",
          "operation" => effect.context["operation"]
        }
      ]
    )
  end

  defp operation_facts(module) do
    module
    |> MLIR.Module.body()
    |> Walker.operations()
    |> Enum.filter(&(MLIR.Operation.name(&1) == "ex.func"))
    |> Enum.flat_map(&function_facts/1)
  end

  defp function_facts(func) do
    function = attribute_string(func, "sym_name") || "unknown"
    arity = function_arity(func)

    func
    |> all_operations()
    |> Enum.reject(&MLIR.equal?(&1, func))
    |> Enum.map(&operation_fact(&1, function, arity))
    |> Enum.reject(&is_nil/1)
  end

  defp operation_fact(op, function, arity) do
    operation = MLIR.Operation.name(op)

    if String.starts_with?(operation, "ex.") do
      %{
        operation: operation,
        function: function,
        arity: arity,
        signature: structural_signature(op),
        callee: if(operation == "ex.call", do: attribute_string(op, "callee")),
        location: op |> MLIR.Operation.location() |> MLIR.to_string()
      }
    end
  end

  defp fact_identity(fact) do
    %{
      "callee" => fact.callee,
      "function" => fact.function,
      "operation" => fact.operation,
      "signature" => fact.signature
    }
  end

  defp structural_signature(op) do
    op
    |> MLIR.to_string(generic: true)
    |> String.replace(~r/%(?:arg)?[0-9]+/, "%value")
    |> String.replace(~r/\^bb[0-9]+/, "^block")
    |> String.replace(~r/loc\([^\n]*\)$/, "")
    |> String.trim()
  end

  defp call_provenance(%{operation: "ex.call", callee: callee}, _provenance, local_symbols) do
    if MapSet.member?(local_symbols, callee) do
      {"batata.memory.local_summary.missing", "local"}
    else
      {"batata.external.summary.missing", "external"}
    end
  end

  defp call_provenance(_fact, provenance, _local_symbols), do: {provenance, nil}

  defp local_symbols(module) do
    module
    |> MLIR.Module.body()
    |> Walker.operations()
    |> Enum.filter(&(MLIR.Operation.name(&1) == "ex.func"))
    |> Enum.map(&attribute_string(&1, "sym_name"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp function_arity(func) do
    func
    |> Walker.regions()
    |> Enum.to_list()
    |> List.first()
    |> case do
      nil -> 0
      region -> region |> Walker.blocks() |> Enum.to_list() |> List.first() |> block_arity()
    end
  end

  defp block_arity(nil), do: 0
  defp block_arity(block), do: block |> Walker.arguments() |> Enum.count()

  defp all_operations(operation) do
    {_, operations} =
      Walker.postwalk(operation, [], fn
        %MLIR.Operation{} = op, acc -> {op, [op | acc]}
        entity, acc -> {entity, acc}
      end)

    Enum.reverse(operations)
  end

  defp attribute_string(op, name) do
    case MLIR.Operation.fetch(op, name) do
      {:ok, attribute} -> attribute |> MLIR.CAPI.mlirStringAttrGetValue() |> MLIR.to_string()
      :error -> nil
    end
  end

  defp compiler_version do
    case Application.spec(:batata, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp dependency_lock(opts) do
    case Keyword.get(opts, :dependency_lock) do
      nil ->
        @native_lock_hash

      lock when is_binary(lock) ->
        lock

      lock ->
        raise ArgumentError, "memory dependency_lock must be a string, got: #{inspect(lock)}"
    end
  end

  defp source_bytes(source) when is_binary(source), do: source
  defp source_bytes(source), do: :erlang.term_to_binary(source, [:deterministic])

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
