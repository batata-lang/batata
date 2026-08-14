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
  test "exposes the next blocker after expanding Jason's module aliases", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "encode.ex"), """
    defmodule Fixture.Encode do
      for module <- [Date, Time, NaiveDateTime, DateTime] do
        defp struct(map, unquote(module)), do: map
      end
    end
    """)

    assert [attempt] = tmp_dir |> Inventory.discover!() |> GenerationAttempt.run()
    assert attempt["expanded_definition_count"] == 4
    assert attempt["compile_phase"] == "frontend_normalization_failure"
    assert attempt["phase"] == "frontend_normalization_failure"
    assert attempt["error"] == "Batata.Lift.Error"
    assert attempt["reason_class"] == "multi_clause_trailing_literal_pattern"
    assert byte_size(attempt["fingerprint"]) == 64
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

  defp unsupported(source) do
    form = Code.string_to_quoted!(source)

    %{
      reason: :module_level_generation,
      generation_construct: :definition_generation,
      generation_root: "for/2",
      form_ast: form
    }
  end
end
