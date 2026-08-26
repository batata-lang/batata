defmodule Batata.Probe.CompileAttemptTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CompileAttempt
  alias Batata.Probe.Inventory

  @tag :tmp_dir
  test "attaches canonical closure evidence without changing the failure", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "external.ex"), """
    defmodule External do
      def apply(fun, value), do: fun.(value)
    end
    """)

    attempts = tmp_dir |> Inventory.discover!() |> CompileAttempt.run()

    assert [attempt] = attempts
    assert attempt["status"] == "frontend_normalization_failure"
    assert attempt["reason_class"] == "dynamic_apply_without_local_dispatch"
    assert byte_size(attempt["fingerprint"]) == 64

    assert attempt["closure_frontier"] == %{
             "kind" => "external_closure",
             "local_fn_count" => 0,
             "sites" => [
               %{
                 "arity" => 2,
                 "function" => "apply",
                 "line" => 2,
                 "provenance" => "caller_parameter"
               }
             ]
           }
  end

  test "fingerprints equivalent Lift failures deterministically" do
    first =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message:
          "unsupported AST in the current slice: Jason.Decoder.parse at /tmp/one.ex:12:8 #PID<0.1.0>"
      })

    second =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message:
          "unsupported AST in the current slice: Jason.Decoder.parse at /private/tmp/two.ex:98:2 #PID<0.9.0>"
      })

    assert first["error"] == "Batata.Lift.Error"
    assert first["reason_class"] == "remote_module_call"
    assert first["fingerprint"] == second["fingerprint"]
    assert byte_size(first["fingerprint"]) == 64
  end

  test "distinguishes stable failure reasons" do
    unsupported =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: "unsupported AST in the current slice: {:receive, [], []}"
      })

    stdlib =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: "unsupported stdlib call: Enum.zip/2"
      })

    assert unsupported["reason_class"] == "unsupported_ast"
    assert stdlib["reason_class"] == "unsupported_stdlib_call"
    refute unsupported["fingerprint"] == stdlib["fingerprint"]
  end

  test "classifies default arguments rejected as parameter patterns" do
    details =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: ~S"unsupported parameter pattern: {:\\, [line: 2], [{:opts, [], nil}, []]}"
      })

    assert details["reason_class"] == "default_argument_pattern"
  end

  test "classifies unexpanded alias AST remote calls" do
    details =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message:
          "unsupported AST in the current slice: {:__aliases__, [line: 4], [:Jason, :Decoder]}.parse"
      })

    assert details["reason_class"] == "remote_module_call"
  end

  test "classifies map patterns and non-exhaustive clauses" do
    map_pattern =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: "unsupported case pattern: {:%{}, [line: 4], [message: {:message, [], nil}]}"
      })

    non_exhaustive =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: "case requires a final catch-all clause"
      })

    assert map_pattern["reason_class"] == "map_pattern"
    assert non_exhaustive["reason_class"] == "non_exhaustive_clauses"
  end

  test "classifies a single guarded definition without a fallback" do
    details =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message: "a guarded function requires a following fallback clause: new/1"
      })

    assert details["reason_class"] == "guarded_definition"
  end

  test "classifies multi-clause trailing literal patterns" do
    details =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message:
          "multi-clause trailing arguments must be variables: {:__aliases__, [line: 2], [:Date]}"
      })

    assert details["reason_class"] == "multi_clause_trailing_literal_pattern"
  end

  test "classifies integer literals outside the tagged term domain" do
    details =
      CompileAttempt.failure_details(%Batata.Lift.Error{
        message:
          "integer literal 1152921504606846976 is outside the signed 61-bit term domain " <>
            "(-1152921504606846976..1152921504606846975)"
      })

    assert details["reason_class"] == "oversized_integer_literal"
  end

  test "classifies unresolved calls reported by standard lowering passes" do
    short_circuit_and =
      CompileAttempt.failure_details(%Batata.Lower.Error{
        message:
          ~S(standard MLIR lowering pass failed: 'func.call' op '&&' does not reference a valid function; callee = @"&&")
      })

    concat =
      CompileAttempt.failure_details(%Batata.Lower.Error{
        message:
          ~S(standard MLIR lowering pass failed: 'func.call' op '<>' does not reference a valid function; callee = @"<>")
      })

    struct =
      CompileAttempt.failure_details(%Batata.Lower.Error{
        message:
          "standard MLIR lowering pass failed: 'func.call' op '__aliases__' does not reference a valid function; callee = @__aliases__"
      })

    conditional =
      CompileAttempt.failure_details(%Batata.Lower.Error{
        message:
          "standard MLIR lowering pass failed: 'func.call' op 'if' does not reference a valid function; callee = @if"
      })

    assert short_circuit_and["reason_class"] == "unresolved_short_circuit_and"
    assert concat["reason_class"] == "unresolved_binary_concat"
    assert struct["reason_class"] == "unresolved_struct_constructor"
    assert conditional["reason_class"] == "unresolved_if"
  end
end
