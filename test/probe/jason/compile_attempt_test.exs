defmodule Batata.Probe.Jason.CompileAttemptTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.CompileAttempt

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
