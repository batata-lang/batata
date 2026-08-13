defmodule Batata.Probe.Jason.DiagnosticAttemptTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{DiagnosticAttempt, Inventory}

  @tag :tmp_dir
  test "marks blocker-stripped exception attempts as diagnostic-only", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "error.ex"), """
    defmodule Fixture.Error do
      defexception [:message]
      def message(%{message: message}), do: message
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["module"] == "Fixture.Error"
    assert attempt["diagnostic_only"]
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["phase"] == "lowering_complete"
    refute Map.has_key?(attempt, "reason_class")

    assert [%{"id" => id, "reason" => "exception_semantics"}] =
             attempt["removed_blockers"]

    assert byte_size(id) == 64
  end

  @tag :tmp_dir
  test "does not compile macro-only modules as synthetic coverage", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "macros.ex"), """
    defmodule Fixture.Macros do
      defmacro generated(value), do: value
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["diagnostic_only"]
    assert attempt["outcome"] == "synthetic_only"
    assert attempt["phase"] == "not_attempted"
    assert [%{"reason" => "macro_definition"}] = attempt["removed_blockers"]
    refute Map.has_key?(attempt, "status")
  end
end
