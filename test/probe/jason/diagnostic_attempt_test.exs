defmodule Batata.Probe.Jason.DiagnosticAttemptTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{DiagnosticAttempt, Inventory}

  @tag :tmp_dir
  test "does not shadow exceptions accepted by compile eligibility", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "error.ex"), """
    defmodule Fixture.Error do
      defexception [:message]
      def message(%{message: message}), do: message
    end
    """)

    assert [] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()

    [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)
    assert module.compile_source =~ "defexception [:message]"
    assert module.unsupported == []
  end

  @tag :tmp_dir
  test "does not shadow structs accepted by compile eligibility", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "ordered_object.ex"), """
    defmodule Fixture.OrderedObject do
      @behaviour Access
      defstruct values: []
      def empty(), do: %__MODULE__{}
      def values(%__MODULE__{values: values}), do: values
    end
    """)

    assert [] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()

    [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)
    assert module.compile_source =~ "defstruct values: []"
    assert module.compile_source =~ "@behaviour Access"
    assert module.unsupported |> Enum.map(& &1.reason) == [:ignored_metadata]
  end

  @tag :tmp_dir
  test "does not strip unrelated blockers from struct diagnostic attempts", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "fragment.ex"), """
    defmodule Fixture.Fragment do
      defstruct [:value]
      def value(%__MODULE__{value: value}) when is_function(value, 5), do: value
    end
    """)

    assert [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)

    assert Enum.map(module.unsupported, & &1.reason) == [:guarded_definition]

    assert module.diagnostic_source == nil
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

  @tag :tmp_dir
  test "keeps ordinary definitions when removing top-level macro blockers", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mixed.ex"), """
    defmodule Fixture.Mixed do
      defmacro generated(value), do: value
      def main(), do: 42
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["diagnostic_only"]
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["phase"] == "lowering_complete"
    assert [%{"reason" => "macro_definition"}] = attempt["removed_blockers"]
  end

  test "records the next Jason.Codegen frontier after removing its macro definitions" do
    attempts =
      Mix.Project.deps_paths()[:jason]
      |> Inventory.discover!()
      |> DiagnosticAttempt.run()

    assert attempt = Enum.find(attempts, &(&1["module"] == "Jason.Codegen"))
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["phase"] == "frontend_normalization_failure"
    assert attempt["reason_class"] == "unsupported_stdlib_call"

    assert attempt["fingerprint"] ==
             "aa6848c4ab8fbdf0573437c27c1a452a9f89807bc1a5a44cef99ed3f476f7db1"

    assert Enum.map(attempt["removed_blockers"], & &1["reason"]) ==
             ["macro_definition", "macro_definition"]
  end
end
