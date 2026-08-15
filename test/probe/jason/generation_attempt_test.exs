defmodule Batata.Probe.Jason.GenerationAttemptTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{GenerationAttempt, Inventory}

  @tag :tmp_dir
  test "expands a bounded literal-list for and records the compile frontier", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "literal_for.ex"), """
    defmodule Fixture.LiteralFor do
      for number <- [1, 2, 3] do
        defp tab(unquote(number)), do: unquote(number)
      end
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> GenerationAttempt.run()
    assert attempt["module"] == "Fixture.LiteralFor"
    assert attempt["generation_root"] == "for/2"
    assert attempt["diagnostic_only"]
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["compile_phase"] == "pass"
    assert attempt["phase"] in ["lowering_failure", "lowering_complete"]
    assert attempt["expanded_definition_count"] == 3

    assert attempt["removed_scope"] == %{
             "accepted_definitions" => 0,
             "unsupported_forms" => 0
           }

    assert byte_size(attempt["blocker_id"]) == 64
  end

  @tag :tmp_dir
  test "lowers generated Jason module-alias clauses", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "encode.ex"), """
    defmodule Fixture.Encode do
      for module <- [Date, Time, NaiveDateTime, DateTime] do
        defp struct(map, unquote(module)), do: map
      end
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> GenerationAttempt.run()
    assert attempt["expanded_definition_count"] == 4
    assert attempt["outcome"] == "reached_compile_pipeline"
    assert attempt["compile_phase"] == "pass"
    assert attempt["phase"] == "lowering_complete"
    refute Map.has_key?(attempt, "error")
    refute Map.has_key?(attempt, "reason_class")
    refute Map.has_key?(attempt, "fingerprint")
  end

  @tag :tmp_dir
  test "rejects ranges, multiple generators, filters, and non-definition bodies", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "rejected.ex"), """
    defmodule Fixture.Rejected do
      for depth <- 1..16, do: defp(range(unquote(depth)), do: depth)
      for left <- [1], right <- [2], do: defp(pair(unquote(left), unquote(right)), do: 0)
      for item <- [1], item > 0, do: defp(filtered(unquote(item)), do: item)
      for item <- [1], do: IO.puts(item)
    end
    """)

    assert tmp_dir |> Inventory.discover!() |> GenerationAttempt.run() == []
  end

  test "rejects bare generator references and nested evaluation forms" do
    module_name = "Fixture.Strict"

    for source <- [
          """
          for item <- [1] do
            defp bare() do
              item
            end
          end
          """,
          """
          for item <- [1] do
            defp fun() do
              fn -> unquote(item) end
            end
          end
          """,
          """
          for item <- [1] do
            defp quoted() do
              quote do
                unquote(item)
              end
            end
          end
          """,
          """
          for item <- [1] do
            defmacro generated() do
              unquote(item)
            end
          end
          """,
          """
          for item <- [remote()] do
            defp generated(unquote(item)) do
              0
            end
          end
          """
        ] do
      unsupported = unsupported(source)
      assert GenerationAttempt.expand_candidate(unsupported, module_name) == :error
    end
  end

  test "selects only the bounded version-gated branch for the current toolchain" do
    assert {:ok, low_literal} =
             GenerationAttempt.expand_candidate(
               version_if("0.0.0", "selected_else", "selected_then"),
               "Fixture.LowLiteral"
             )

    assert low_literal.generation_root == "if/2"
    assert low_literal.expanded_definition_count == 1
    assert low_literal.source =~ "selected_else"
    refute low_literal.source =~ "selected_then"

    assert {:ok, high_literal} =
             GenerationAttempt.expand_candidate(
               version_if("9999.0.0", "selected_else", "selected_then"),
               "Fixture.HighLiteral"
             )

    assert high_literal.generation_root == "if/2"
    assert high_literal.expanded_definition_count == 1
    assert high_literal.source =~ "selected_then"
    refute high_literal.source =~ "selected_else"
  end

  test "accepts reversed do/else option order without changing selection" do
    unsupported = version_if("0.0.0", "selected_else", "selected_then")
    {:if, metadata, [condition, options]} = unsupported.form_ast
    reversed = %{unsupported | form_ast: {:if, metadata, [condition, Enum.reverse(options)]}}

    assert {:ok, expansion} =
             GenerationAttempt.expand_candidate(reversed, "Fixture.ReversedOptions")

    assert expansion.source =~ "selected_else"
    refute expansion.source =~ "selected_then"
  end

  test "rejects malformed or broader version-gated conditions" do
    module_name = "Fixture.RejectedVersionIf"

    for source <- [
          version_if_source("not-a-version"),
          version_if_source("1.0"),
          version_if_source("1.3.0", operator: "!="),
          version_if_source("1.3.0", comparison: ":gt"),
          version_if_source("1.3.0", swap_operands: true),
          """
          version = "1.3.0"
          if Version.compare(System.version(), version) == :lt do
            defp selected_then(), do: :then
          else
            defp selected_else(), do: :else
          end
          """,
          """
          if Version.compare(File.read!("version"), "1.3.0") == :lt do
            defp selected_then(), do: :then
          else
            defp selected_else(), do: :else
          end
          """,
          """
          if Version.compare(System.version(), "1.3.0") == :lt do
            defp selected_then(), do: :then
          end
          """,
          """
          if Version.compare(System.version(), "1.3.0") == :lt do
            defmacro selected_then(), do: :then
          else
            defp selected_else(), do: :else
          end
          """,
          """
          if Version.compare(System.version(), "1.3.0") == :lt do
            defp selected_then(), do: fn -> :then end
          else
            defp selected_else(), do: :else
          end
          """,
          """
          if Version.compare(System.version(), "1.3.0") == :lt do
            defp selected_then(), do: :then
          else
            defp selected_else(), do: quote(do: :else)
          end
          """
        ] do
      assert source |> unsupported("if/2") |> GenerationAttempt.expand_candidate(module_name) ==
               :error
    end

    valid = version_if("1.3.0", "selected_else", "selected_then")
    {:if, metadata, [condition, options]} = valid.form_ast
    duplicate = %{valid | form_ast: {:if, metadata, [condition, [hd(options) | options]]}}

    extra =
      %{valid | form_ast: {:if, metadata, [condition, options ++ [unexpected: true]]}}

    assert GenerationAttempt.expand_candidate(duplicate, module_name) == :error
    assert GenerationAttempt.expand_candidate(extra, module_name) == :error
  end

  defp unsupported(source, generation_root \\ "for/2") do
    form = Code.string_to_quoted!(source)

    %{
      reason: :module_level_generation,
      generation_construct: :definition_generation,
      generation_root: generation_root,
      form_ast: form
    }
  end

  defp version_if(version, else_name, then_name) do
    version_if_source(version, else_name: else_name, then_name: then_name)
    |> unsupported("if/2")
  end

  defp version_if_source(version, opts \\ []) do
    operator = Keyword.get(opts, :operator, "==")
    comparison = Keyword.get(opts, :comparison, ":lt")
    else_name = Keyword.get(opts, :else_name, "selected_else")
    then_name = Keyword.get(opts, :then_name, "selected_then")

    {left, right} =
      if Keyword.get(opts, :swap_operands, false) do
        {comparison, "Version.compare(System.version(), \"#{version}\")"}
      else
        {"Version.compare(System.version(), \"#{version}\")", comparison}
      end

    """
    if #{left} #{operator} #{right} do
      defp #{then_name}(), do: :then
    else
      defp #{else_name}(), do: :else
    end
    """
  end
end
