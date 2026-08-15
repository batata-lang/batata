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
  test "preserves current-module struct schemas in diagnostic attempts", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "ordered_object.ex"), """
    defmodule Fixture.OrderedObject do
      @behaviour Access
      defstruct values: []
      def empty(), do: %__MODULE__{}
      def values(%__MODULE__{values: values}), do: values
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["module"] == "Fixture.OrderedObject"
    assert attempt["diagnostic_only"]
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["phase"] == "lowering_complete"
    assert [%{"reason" => "struct_semantics"}] = attempt["removed_blockers"]

    [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)
    assert module.diagnostic_source =~ "defstruct values: []"
    refute module.diagnostic_source =~ "@behaviour"
  end

  @tag :tmp_dir
  test "does not strip unrelated blockers from struct diagnostic attempts", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "fragment.ex"), """
    defmodule Fixture.Fragment do
      defstruct [:value]
      def value(%__MODULE__{value: value}) when is_function(value, 1), do: value
    end
    """)

    assert [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)

    assert Enum.map(module.unsupported, & &1.reason) == [
             :struct_semantics,
             :guarded_definition
           ]

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
end
