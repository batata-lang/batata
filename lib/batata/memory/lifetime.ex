defmodule Batata.Memory.Lifetime do
  @moduledoc """
  Conservative escape and lifetime classification over MLIR SSA uses.

  The analysis follows information-preserving container operations so a value
  nested in a returned tuple or sent message receives the same lifetime floor
  as its enclosing value. It never uses runtime telemetry.
  """

  alias Beaver.MLIR
  alias Beaver.Walker

  @escape_rank %{
    local: 0,
    closure_capture: 1,
    return: 2,
    result: 3,
    process_send: 4,
    exported_host: 5
  }

  @type escape :: :local | :closure_capture | :return | :result | :process_send | :exported_host

  @type t :: %{
          escape: escape(),
          lifetime: map(),
          strategy: map()
        }

  @doc "Infers the strongest escape reachable from an operation's SSA results."
  @spec infer(MLIR.Operation.t(), String.t()) :: t()
  def infer(operation, function) do
    escape =
      operation
      |> Walker.results()
      |> Enum.flat_map(&value_escapes(&1, [], 0))
      |> strongest_escape()
      |> promote_entry_return(function)

    for_escape(escape)
  end

  @doc "Merges equivalent sites conservatively by selecting the strongest escape."
  @spec merge([t()]) :: t()
  def merge(lifetimes) when is_list(lifetimes) do
    lifetimes
    |> Enum.map(& &1.escape)
    |> strongest_escape()
    |> for_escape()
  end

  defp value_escapes(_value, _seen, depth) when depth >= 64, do: [:return]

  defp value_escapes(value, seen, depth) do
    value
    |> Walker.uses()
    |> Enum.flat_map(fn use ->
      owner = MLIR.OpOperand.owner(use)

      if Enum.any?(seen, &MLIR.equal?(&1, owner)) do
        []
      else
        owner_escapes(owner, MLIR.OpOperand.operand_number(use), [owner | seen], depth + 1)
      end
    end)
  end

  defp owner_escapes(owner, operand, seen, depth) do
    case {MLIR.Operation.name(owner), operand} do
      {"ex.send", 1} ->
        [:process_send]

      {name, _} when name in ["ex.term_export", "ex.term_handle_export"] ->
        [:exported_host]

      {name, _} when name in ["ex.result_create", "ex.result_create_term"] ->
        [:result]

      {name, _}
      when name in [
             "ex.make_fun",
             "ex.make_fun_with_arity",
             "ex.make_fun_with_signature",
             "ex.spawn"
           ] ->
        [:closure_capture]

      {"ex.return", _} ->
        [:return]

      {"scf.yield", _} ->
        owner |> MLIR.Operation.parent() |> operation_result_escapes(seen, depth)

      _other ->
        operation_result_escapes(owner, seen, depth)
    end
  end

  defp operation_result_escapes(operation, seen, depth) do
    operation
    |> Walker.results()
    |> Enum.flat_map(&value_escapes(&1, seen, depth))
  end

  defp strongest_escape([]), do: :local
  defp strongest_escape(escapes), do: Enum.max_by(escapes, &Map.fetch!(@escape_rank, &1))

  defp promote_entry_return(:return, function)
       when function in ["__batata_entry", "batata_main"],
       do: :result

  defp promote_entry_return(escape, _function), do: escape

  @doc "Returns the canonical lifetime contract for an escape class."
  @spec for_escape(escape()) :: t()
  def for_escape(:local) do
    %{
      escape: :local,
      lifetime: %{"end" => "last-use", "scope" => "execution"},
      strategy: %{"id" => "retain-execution-arena", "requires" => ["execution epoch is live"]}
    }
  end

  def for_escape(:closure_capture) do
    %{
      escape: :closure_capture,
      lifetime: %{"end" => "closure-release", "scope" => "execution"},
      strategy: %{"id" => "retain-closure-environment", "requires" => ["same execution epoch"]}
    }
  end

  def for_escape(:return) do
    %{
      escape: :return,
      lifetime: %{"end" => "caller-last-use", "scope" => "execution"},
      strategy: %{"id" => "retain-through-caller", "requires" => ["same execution epoch"]}
    }
  end

  def for_escape(:result) do
    %{
      escape: :result,
      lifetime: %{"end" => "result-handle-destroy", "scope" => "pinned-execution"},
      strategy: %{
        "id" => "pin-execution-arena",
        "requires" => ["generation-checked result handle", "reset waits for pin release"]
      }
    }
  end

  def for_escape(:process_send) do
    %{
      escape: :process_send,
      lifetime: %{"end" => "execution-quiescence", "scope" => "actor-message"},
      strategy: %{
        "id" => "retain-in-execution-arena",
        "requires" => ["sender and receiver share execution epoch", "quiescence before reset"]
      }
    }
  end

  def for_escape(:exported_host) do
    %{
      escape: :exported_host,
      lifetime: %{"end" => "export-handle-destroy", "scope" => "host"},
      strategy: %{
        "id" => "copy-to-exported-host-storage",
        "requires" => ["portable deep export", "exclusive export lease"]
      }
    }
  end
end
