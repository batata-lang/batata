defmodule Batata.Memory.Summary do
  @moduledoc "Closed size summaries for allocation-producing `ex` operations."

  alias Batata.Memory.{Bound, Inventory, Site}

  @word_bytes 8

  @type result :: %{
          classification: Batata.Memory.Effect.classification(),
          size: Bound.t() | nil,
          failure: atom() | nil,
          provenance: String.t(),
          obligation: nil | {atom(), String.t(), [map()]}
        }

  @doc "Returns a conservative allocation summary for one reachable operation."
  @spec infer(String.t(), non_neg_integer(), Site.t(), keyword()) :: result()
  def infer(operation, operands, %Site{} = site, opts) do
    inventory = Inventory.intrinsic(operation)

    case {inventory.classification, exact_bytes(operation, operands)} do
      {:none, _} ->
        closed(:none, Bound.constant(0), inventory.provenance)

      {_classification, bytes} when is_integer(bytes) ->
        closed(:exact, Bound.constant(bytes), "batata.memory.runtime_layout/1")

      {:may_allocate, nil} ->
        dynamic(operation, site, opts)

      {:unknown, nil} ->
        unknown(operation, inventory.provenance)
    end
  end

  @doc "Stable contract variable used to close a dynamic allocation site."
  @spec contract_variable(Site.t()) :: String.t()
  def contract_variable(%Site{id: id}), do: "allocation-bytes:" <> id

  defp dynamic(operation, site, opts) do
    variable = contract_variable(site)
    contracts = Keyword.get(opts, :contracts, %{})
    quota_bytes = Keyword.get(opts, :quota_bytes)

    case contracts[variable] do
      bytes when is_integer(bytes) and bytes >= 0 ->
        %{
          classification: :parametric,
          size: Bound.variable(variable),
          failure: nil,
          provenance: "batata.memory.contract/1",
          obligation: nil
        }

      _missing when is_integer(quota_bytes) and quota_bytes >= 0 ->
        %{
          classification: :guarded,
          size: Bound.constant(0),
          failure: :arena_oom,
          provenance: "batata.memory.runtime_quota/1",
          obligation: nil
        }

      _missing ->
        %{
          classification: :parametric,
          size: Bound.variable(variable),
          failure: nil,
          provenance: "batata.memory.contract.missing",
          obligation:
            {:allocation_precondition_missing,
             "an upper-bound contract for dynamic allocation #{operation}",
             [
               %{
                 "action" => "set-memory-contract",
                 "maximum_bytes" => "non-negative integer",
                 "variable" => variable
               },
               %{
                 "action" => "set-runtime-quota",
                 "failure_effect" => "arena_oom"
               }
             ]}
        }
    end
  end

  defp unknown(operation, provenance) do
    %{
      classification: :unknown,
      size: nil,
      failure: nil,
      provenance: provenance,
      obligation:
        {:allocation_effect_unknown, "an explicit allocation effect for #{operation}",
         [%{"action" => "classify-intrinsic", "operation" => operation}]}
    }
  end

  defp closed(classification, size, provenance) do
    %{
      classification: classification,
      size: size,
      failure: nil,
      provenance: provenance,
      obligation: nil
    }
  end

  # Layouts mirror native/term_runtime.zig. Immediate values allocate zero.
  defp exact_bytes("ex.tuple", operands), do: (operands + 1) * @word_bytes
  defp exact_bytes("ex.list", operands), do: operands * 2 * @word_bytes
  defp exact_bytes("ex.list_cons", _operands), do: 2 * @word_bytes
  defp exact_bytes("ex.map", operands), do: (operands + 1) * @word_bytes

  defp exact_bytes("ex.binary", operands) do
    (1 + div(operands + @word_bytes - 1, @word_bytes)) * @word_bytes
  end

  defp exact_bytes("ex.float_lit", _operands), do: @word_bytes
  defp exact_bytes("ex.make_fun", _operands), do: 6 * @word_bytes
  defp exact_bytes("ex.make_fun_with_arity", _operands), do: 7 * @word_bytes
  defp exact_bytes(_operation, _operands), do: nil
end
