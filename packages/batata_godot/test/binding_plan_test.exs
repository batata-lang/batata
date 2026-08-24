defmodule Batata.Godot.BindingPlanTest.Example do
  use Batata.Godot.Extension,
    extension: "batata_example",
    compatibility_minimum: "4.6",
    initialization_level: :scene

  godot_class("BatataExample", base: "RefCounted")
  godot_method(:subtract, args: [:int, :int], returns: :int)
  godot_method(:add, args: [:int, :int], returns: :int)

  def add(left, right), do: left + right
  def subtract(left, right), do: left - right
end

defmodule Batata.Godot.BindingPlanTest do
  use ExUnit.Case, async: true

  alias Batata.Godot.{BindingPlan, Diagnostic}
  alias Batata.Godot.BindingPlanTest.Example

  test "extension declarations embed a sorted binding plan" do
    plan = Batata.Godot.binding_plan(Example)

    assert plan.extension == "batata_example"
    assert plan.entry_symbol == "batata_example_library_init"
    assert plan.compatibility_minimum == "4.6"
    assert plan.reloadable == false
    assert plan.initialization_level == :scene
    assert plan.class == %BindingPlan.Class{name: "BatataExample", base: "RefCounted"}

    assert Enum.map(plan.methods, &{&1.name, &1.symbol}) == [
             {"add", "__batata_fn_616464_2"},
             {"subtract", "__batata_fn_7375627472616374_2"}
           ]
  end

  test "canonical JSON and digest are replayable" do
    json = Batata.Godot.canonical_json(Example)

    assert JSON.decode!(json) ==
             Example
             |> Batata.Godot.binding_plan()
             |> BindingPlan.canonical_map()

    assert json == Batata.Godot.canonical_json(Example)

    assert Batata.Godot.digest(Example) ==
             "a6b7601274dc56231dbe2eedeee60034b2ece4cdc94c3694dc6f2b5e15daa8f8"
  end

  test "unsupported Variant types fail closed with a recovery action" do
    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(
          Example,
          [],
          [{"BatataExample", []}],
          [{:consume, [args: [:dictionary], returns: nil]}],
          consume: 1
        )
      end

    assert error.code == "E_GODOT_VARIANT_UNSUPPORTED"
    assert error.context.type == ":dictionary"
    assert Diagnostic.to_map(error)["recoverable"]
  end

  test "text and vector declarations are closed value types" do
    plan =
      BindingPlan.new!(
        Example,
        [],
        [{"BatataExample", []}],
        [
          {:echo_string, [args: [:string], returns: :string]},
          {:echo_name, [args: [:string_name], returns: :string_name]},
          {:echo_vector2, [args: [:vector2], returns: :vector2]},
          {:echo_vector3, [args: [:vector3], returns: :vector3]},
          {:echo_object, [args: [{:object, "RefCounted"}], returns: {:object, "RefCounted"}]}
        ],
        echo_string: 1,
        echo_name: 1,
        echo_vector2: 1,
        echo_vector3: 1,
        echo_object: 1
      )

    assert Enum.map(plan.methods, &{&1.arguments, &1.returns}) == [
             {[:string_name], :string_name},
             {[object: "RefCounted"], {:object, "RefCounted"}},
             {[:string], :string},
             {[:vector2], :vector2},
             {[:vector3], :vector3}
           ]
  end

  test "opaque object declarations require a concrete Godot class" do
    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(
          Example,
          [],
          [{"BatataExample", []}],
          [{:echo_object, [args: [{:object, "bad class"}], returns: nil]}],
          echo_object: 1
        )
      end

    assert error.code == "E_GODOT_IDENTIFIER_INVALID"
    assert error.context.field == :object_class
  end

  test "a method declaration must resolve to a public function" do
    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(
          Example,
          [],
          [{"BatataExample", []}],
          [{:missing, [args: [:int], returns: :int]}],
          []
        )
      end

    assert error.code == "E_GODOT_METHOD_FUNCTION_MISSING"
    assert error.context.function == "missing/1"
  end

  test "duplicate method signatures fail before native generation" do
    declaration = {:add, [args: [:int, :int], returns: :int]}

    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(
          Example,
          [],
          [{"BatataExample", []}],
          [declaration, declaration],
          add: 2
        )
      end

    assert error.code == "E_GODOT_METHOD_DUPLICATE"
    assert error.context.signatures == ["add/2"]
  end

  test "method arity beyond the fixed trampoline surface fails closed" do
    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(
          Example,
          [],
          [{"BatataExample", []}],
          [{:wide, [args: List.duplicate(:int, 9), returns: :int]}],
          wide: 9
        )
      end

    assert error.code == "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED"
    assert error.context == %{method: :wide, arity: 9, maximum: 8}
  end

  test "an extension requires exactly one class" do
    error = assert_raise Diagnostic, fn -> BindingPlan.new!(Example, [], [], [], []) end

    assert error.code == "E_GODOT_CLASS_MISSING"
  end

  test "unknown declaration options fail closed" do
    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(Example, [dynamic: true], [{"BatataExample", []}], [], [])
      end

    assert error.code == "E_GODOT_OPTION_UNKNOWN"
    assert error.context.options == [:dynamic]
  end

  test "plain modules do not masquerade as extensions" do
    error = assert_raise Diagnostic, fn -> Batata.Godot.binding_plan(String) end

    assert error.code == "E_GODOT_BINDING_PLAN_MISSING"
  end
end
