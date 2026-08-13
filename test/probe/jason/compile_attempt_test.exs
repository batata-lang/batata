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
end
