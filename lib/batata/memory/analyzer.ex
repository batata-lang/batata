defmodule Batata.Memory.Analyzer do
  @moduledoc """
  Builds a fail-closed memory plan from reachable, verified `ex` IR.

  Allocation sites are structural equivalence classes rather than traversal
  ordinals. M1 adds reachable-call analysis, exact runtime-layout sizes, and a
  deliberately small symbolic language for loop, recursion, and dynamic-site
  contracts.
  """

  alias Batata.Memory
  alias Batata.Memory.{Bound, Effect, Inventory, Obligation, Plan, Site, Summary}
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
          operands: non_neg_integer(),
          callee: String.t() | nil,
          location: String.t(),
          loop_depth: non_neg_integer()
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
    contracts = validate_contracts!(Keyword.get(opts, :contracts, %{}))
    quota_bytes = validate_quota!(Keyword.get(opts, :quota_bytes))

    all_facts = operation_facts(module)
    facts_by_function = Enum.group_by(all_facts, & &1.function)
    local_symbols = facts_by_function |> Map.keys() |> MapSet.new()
    roots = entry_roots(local_symbols)
    reachable = reachable_functions(roots, facts_by_function, local_symbols)
    graph = call_graph(reachable, facts_by_function, local_symbols)
    recursive = recursive_functions(graph)
    invocations = invocation_counts(roots, graph, recursive)

    analysis_opts = [contracts: contracts, quota_bytes: quota_bytes, recursive: recursive]

    {effects, obligations} =
      all_facts
      |> Enum.filter(&MapSet.member?(reachable, &1.function))
      |> Enum.group_by(&fact_identity/1)
      |> Enum.map(fn {_identity, facts} ->
        analyze_equivalence_class(
          facts,
          module_name,
          local_symbols,
          invocations,
          analysis_opts
        )
      end)
      |> Enum.sort_by(fn {effect, _obligation} -> effect.site.id end)
      |> Enum.unzip()

    obligations = Enum.reject(obligations, &is_nil/1)
    maximum_memory = total_bound(effects, quota_bytes)

    Plan.new!(
      policy: policy,
      source_hash: sha256(source_bytes(source)),
      compiler_version: compiler_version(),
      dependency_lock: dependency_lock(opts),
      maximum_memory: maximum_memory,
      effects: effects,
      obligations: obligations,
      preconditions: preconditions(contracts),
      runtime_guards: runtime_guards(effects, quota_bytes)
    )
  end

  defp analyze_equivalence_class(
         [fact | _] = facts,
         module_name,
         local_symbols,
         invocations,
         opts
       ) do
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

    multiplicity = length(facts) * Map.get(invocations, fact.function, 1)

    context = %{
      "callee_scope" => callee_scope,
      "function_invocations" => Map.get(invocations, fact.function, 1),
      "loop_depth" => fact.loop_depth,
      "multiplicity" => multiplicity,
      "operation" => fact.operation
    }

    summary = summarize(fact, site, local_symbols, Keyword.fetch!(opts, :recursive), opts)

    size =
      summary.size
      |> multiply_control_bound(fact, site, opts)
      |> multiply_multiplicity(multiplicity)

    effect =
      Effect.new!(
        site: site,
        classification: control_classification(summary.classification, fact, opts),
        provenance: if(summary.provenance, do: summary.provenance, else: provenance),
        size: size,
        region: if(summary.classification == :none, do: :immediate, else: :execution_arena),
        failure: summary.failure,
        callee: fact.callee,
        context: context
      )

    obligation =
      summary_obligation(summary, effect) ||
        missing_control_obligation(effect, fact, site, opts)

    {effect, obligation}
  end

  defp summarize(%{operation: "ex.call", callee: callee}, _site, local_symbols, recursive, _opts)
       when is_binary(callee) do
    cond do
      not MapSet.member?(local_symbols, callee) ->
        inventory = Inventory.external(callee)

        %{
          classification: inventory.classification,
          size: nil,
          failure: nil,
          provenance: inventory.provenance,
          obligation: nil
        }

      MapSet.member?(recursive, callee) ->
        %{
          classification: :none,
          size: Bound.constant(0),
          failure: nil,
          provenance: "batata.memory.local_summary.recursive",
          obligation: nil
        }

      true ->
        %{
          classification: :none,
          size: Bound.constant(0),
          failure: nil,
          provenance: "batata.memory.local_summary.closed",
          obligation: nil
        }
    end
  end

  defp summarize(fact, site, _local_symbols, _recursive, opts) do
    Summary.infer(fact.operation, fact.operands, site, opts)
  end

  defp summary_obligation(%{classification: :unknown}, effect) when is_binary(effect.callee) do
    external? = effect.context["callee_scope"] == "external"

    Obligation.new!(
      kind: if(external?, do: :external_summary_missing, else: :callee_summary_missing),
      site: effect.site,
      missing_fact: "a closed allocation summary for callee #{effect.callee}",
      context: effect.context,
      strategies: [
        %{
          "action" =>
            if(external?, do: "declare-external-summary", else: "derive-callee-summary"),
          "callee" => effect.callee
        }
      ]
    )
  end

  defp summary_obligation(%{obligation: nil}, _effect), do: nil

  defp summary_obligation(%{obligation: {kind, missing, strategies}}, effect) do
    Obligation.new!(
      kind: kind,
      site: effect.site,
      missing_fact: missing,
      context: effect.context,
      strategies: strategies
    )
  end

  defp missing_control_obligation(effect, fact, site, opts) do
    variable = control_variable(fact, site, Keyword.fetch!(opts, :recursive))
    contracts = Keyword.fetch!(opts, :contracts)

    if variable && not valid_contract?(contracts[variable]) do
      Obligation.new!(
        kind: if(fact.loop_depth > 0, do: :loop_bound_missing, else: :recursion_bound_missing),
        site: effect.site,
        missing_fact: "a finite iteration contract for #{variable}",
        context: effect.context,
        strategies: [
          %{
            "action" => "set-memory-contract",
            "maximum_iterations" => "non-negative integer",
            "variable" => variable
          }
        ]
      )
    end
  end

  defp multiply_control_bound(nil, _fact, _site, _opts), do: nil

  defp multiply_control_bound(%Bound{} = bound, fact, site, opts) do
    case control_variable(fact, site, Keyword.fetch!(opts, :recursive)) do
      nil -> bound
      variable -> Bound.multiply([bound, Bound.variable(variable)])
    end
  end

  defp multiply_multiplicity(nil, _multiplicity), do: nil
  defp multiply_multiplicity(%Bound{} = bound, multiplicity), do: Bound.scale(bound, multiplicity)

  defp control_classification(:none, _fact, _opts), do: :none

  defp control_classification(classification, fact, opts) do
    if fact.loop_depth > 0 or
         MapSet.member?(Keyword.fetch!(opts, :recursive), fact.function),
       do: :parametric,
       else: classification
  end

  defp control_variable(fact, site, recursive) do
    cond do
      fact.loop_depth > 0 and site != nil -> "iterations:#{fact.function}:#{site.id}"
      MapSet.member?(recursive, fact.function) -> "recursion:#{fact.function}:iterations"
      true -> nil
    end
  end

  defp total_bound(effects, quota_bytes) do
    known = effects |> Enum.map(& &1.size) |> Enum.reject(&is_nil/1) |> Bound.add()

    if is_integer(quota_bytes) and Enum.any?(effects, &(&1.classification == :guarded)),
      do: Bound.maximum([known, Bound.constant(quota_bytes)]),
      else: known
  end

  defp preconditions(contracts) do
    contracts
    |> Enum.map(fn {variable, maximum} ->
      %{"maximum_bytes" => Integer.to_string(maximum), "variable" => variable}
    end)
    |> Enum.sort_by(& &1["variable"])
  end

  defp runtime_guards(effects, quota_bytes) do
    if is_integer(quota_bytes) and Enum.any?(effects, &(&1.classification == :guarded)) do
      [
        %{
          "failure_effect" => "arena_oom",
          "id" => "execution-arena-quota",
          "maximum_bytes" => Integer.to_string(quota_bytes)
        }
      ]
    else
      []
    end
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
        operands: Enum.count(Walker.operands(op)),
        callee: if(operation == "ex.call", do: attribute_string(op, "callee")),
        location: op |> MLIR.Operation.location() |> MLIR.to_string(),
        loop_depth: enclosing_loop_depth(op)
      }
    end
  end

  defp fact_identity(fact) do
    %{
      "callee" => fact.callee,
      "control" => %{"loop_depth" => fact.loop_depth},
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

  defp enclosing_loop_depth(op), do: enclosing_loop_depth(MLIR.Operation.parent(op), 0)

  defp enclosing_loop_depth(parent, depth) do
    if MLIR.null?(parent) do
      depth
    else
      next_depth = if MLIR.Operation.name(parent) == "scf.while", do: depth + 1, else: depth
      enclosing_loop_depth(MLIR.Operation.parent(parent), next_depth)
    end
  end

  defp call_provenance(%{operation: "ex.call", callee: callee}, _provenance, local_symbols) do
    if MapSet.member?(local_symbols, callee) do
      {"batata.memory.local_summary", "local"}
    else
      {"batata.external.summary.missing", "external"}
    end
  end

  defp call_provenance(_fact, provenance, _local_symbols), do: {provenance, nil}

  defp entry_roots(local_symbols) do
    cond do
      MapSet.member?(local_symbols, "main") -> ["main"]
      MapSet.member?(local_symbols, "batata_main") -> ["batata_main"]
      true -> MapSet.to_list(local_symbols)
    end
  end

  defp reachable_functions(roots, facts_by_function, local_symbols) do
    visit_functions(roots, MapSet.new(roots), facts_by_function, local_symbols)
  end

  defp visit_functions([], seen, _facts_by_function, _local_symbols), do: seen

  defp visit_functions([function | pending], seen, facts_by_function, local_symbols) do
    callees =
      facts_by_function
      |> Map.get(function, [])
      |> Enum.map(& &1.callee)
      |> Enum.filter(&(is_binary(&1) and MapSet.member?(local_symbols, &1)))
      |> MapSet.new()
      |> MapSet.difference(seen)
      |> MapSet.to_list()

    visit_functions(
      pending ++ callees,
      MapSet.union(seen, MapSet.new(callees)),
      facts_by_function,
      local_symbols
    )
  end

  defp call_graph(reachable, facts_by_function, local_symbols) do
    Map.new(reachable, fn function ->
      edges =
        facts_by_function
        |> Map.get(function, [])
        |> Enum.map(& &1.callee)
        |> Enum.filter(&(is_binary(&1) and MapSet.member?(local_symbols, &1)))
        |> Enum.frequencies()

      {function, edges}
    end)
  end

  defp recursive_functions(graph) do
    graph
    |> Map.keys()
    |> Enum.filter(fn function -> reaches?(function, function, graph, MapSet.new(), false) end)
    |> MapSet.new()
  end

  defp reaches?(current, target, graph, seen, traversed?) do
    cond do
      traversed? and current == target ->
        true

      MapSet.member?(seen, current) ->
        false

      true ->
        seen = MapSet.put(seen, current)

        graph
        |> Map.get(current, %{})
        |> Map.keys()
        |> Enum.any?(&reaches?(&1, target, graph, seen, true))
    end
  end

  defp invocation_counts(roots, graph, recursive) do
    acyclic =
      Map.new(graph, fn {from, edges} ->
        {from, if(MapSet.member?(recursive, from), do: %{}, else: edges)}
      end)

    base = Map.new(roots, &{&1, 1})

    Enum.reduce(1..max(map_size(acyclic), 1), base, fn _, previous ->
      propagate_invocation_counts(acyclic, base, previous)
    end)
  end

  defp propagate_invocation_counts(graph, base, previous) do
    Enum.reduce(graph, base, fn {from, edges}, counts ->
      caller_count = Map.get(previous, from, 0)
      accumulate_invocation_edges(edges, counts, caller_count)
    end)
  end

  defp accumulate_invocation_edges(edges, counts, caller_count) do
    Enum.reduce(edges, counts, fn {callee, calls}, acc ->
      Map.update(acc, callee, caller_count * calls, &(&1 + caller_count * calls))
    end)
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

  defp validate_contracts!(contracts) when is_map(contracts) do
    if Enum.all?(contracts, fn {key, value} ->
         is_binary(key) and key != "" and valid_contract?(value)
       end) do
      contracts
    else
      raise ArgumentError, "memory_contracts must map non-empty strings to non-negative integers"
    end
  end

  defp validate_contracts!(contracts),
    do: raise(ArgumentError, "memory_contracts must be a map, got: #{inspect(contracts)}")

  defp validate_quota!(nil), do: nil
  defp validate_quota!(bytes) when is_integer(bytes) and bytes >= 0, do: bytes

  defp validate_quota!(bytes),
    do:
      raise(
        ArgumentError,
        "memory_quota_bytes must be a non-negative integer or nil, got: #{inspect(bytes)}"
      )

  defp valid_contract?(value), do: is_integer(value) and value >= 0

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
