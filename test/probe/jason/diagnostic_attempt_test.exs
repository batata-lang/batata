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
  test "records macro-only private helper trees as synthetic coverage", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "macros.ex"), """
    defmodule Fixture.Macros do
      defmacro generated(value), do: helper(value)
      defp helper(value), do: value
    end
    """)

    assert [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)
    assert module.diagnostic_source == nil

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["outcome"] == "synthetic_only"
    assert attempt["phase"] == "not_attempted"
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

  @tag :tmp_dir
  test "slices only private helpers exclusively reachable from removed macros", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "mixed.ex"), """
    defmodule Fixture.Mixed do
      defmacro generated(value), do: macro_first(value)
      defmacro shared_generated(value), do: shared(value)

      defp macro_first(value), do: macro_last(value)
      defp macro_last(:zero), do: 0
      defp macro_last(value), do: value

      defp shared(value), do: value
      defp privately_shared(value), do: macro_last(value)
      defp unrelated(value), do: value
      def public(value), do: shared(value)
    end
    """)

    [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)

    refute module.diagnostic_source =~ "defp macro_first"
    assert module.diagnostic_source =~ "defp macro_last"
    assert module.diagnostic_source =~ "defp shared"
    assert module.diagnostic_source =~ "defp privately_shared"
    assert module.diagnostic_source =~ "defp unrelated"
    assert module.diagnostic_source =~ "def public"

    assert [attempt] = tmp_dir |> Inventory.discover!() |> DiagnosticAttempt.run()
    assert attempt["phase"] == "lowering_complete"
  end

  @tag :tmp_dir
  test "keeps a private helper reached through a local capture from an ordinary root", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "capture.ex"), """
    defmodule Fixture.Capture do
      defmacro generated(value), do: shared(value)
      defp shared(value), do: value
      def public(), do: &shared/1
    end
    """)

    [module] = tmp_dir |> Inventory.discover!() |> hd() |> Map.fetch!(:modules)
    assert module.diagnostic_source =~ "defp shared"
  end

  test "records the next Jason.Codegen frontier after removing its macro definitions" do
    inventory = Mix.Project.deps_paths()[:jason] |> Inventory.discover!()

    assert codegen =
             inventory
             |> Enum.flat_map(& &1.modules)
             |> Enum.find(&(&1.module == "Jason.Codegen"))

    refute codegen.diagnostic_source =~ "defp clauses_to_ranges"
    refute codegen.diagnostic_source =~ "defp literal_clauses"
    refute codegen.diagnostic_source =~ "defp jump_table_to_clauses"
    refute codegen.diagnostic_source =~ "Macro.expand"
    assert codegen.diagnostic_source =~ "def jump_table"
    assert codegen.diagnostic_source =~ "def build_kv_iodata"

    attempts = DiagnosticAttempt.run(inventory)

    assert attempt = Enum.find(attempts, &(&1["module"] == "Jason.Codegen"))
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["phase"] == "frontend_normalization_failure"
    assert attempt["reason_class"] == "remote_module_call"

    assert attempt["fingerprint"] ==
             "77a989f65a142cbcb967a3a8080ea400731e151fcd65d12af97de3224b66a821"

    assert Enum.map(attempt["removed_blockers"], & &1["reason"]) ==
             ["macro_definition", "macro_definition"]
  end
end
