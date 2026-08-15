defmodule Batata.Probe.Jason.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{CompileAttempt, Inventory}

  @tag :tmp_dir
  test "discovers every unsupported form instead of stopping at the first", %{tmp_dir: tmp_dir} do
    source = """
    defmodule Outer do
      @moduledoc false
      @behaviour Access
      @compile {:inline, plain: 1}
      @dialyzer :no_improper_lists
      @impl Access
      @compile {:always, plain: 1}
      @dialyzer {:nowarn_function, plain: 1}
      @impl false
      @semantic_key :value
      @digits Enum.to_list(0..9)
      import Bitwise
      defstruct [:value]
      defexception [:message]
      defrecordp :state, value: nil
      defmacro generated(value), do: value
      generated :value
      for value <- [1], do: defp(generated_value(), do: value)
      def guarded(value) when is_integer(value), do: value
      def at_end(position, data) when position == byte_size(data), do: position
      def unsupported(value) when is_function(value, 1), do: value
      def plain(value), do: value

      defmodule Inner do
        require Logger
        def child(), do: 1
      end
    end
    """

    path = Path.join(tmp_dir, "sample.ex")
    File.write!(path, source)

    assert [file] = Inventory.discover!(tmp_dir)
    assert file.status == :parsed
    assert Enum.map(file.modules, & &1.module) == ["Outer", "Outer.Inner"]

    [outer, inner] = file.modules
    assert outer.compile_source == nil
    assert inner.compile_source == nil

    assert outer.definitions == [
             %{kind: :def, name: :guarded, arity: 1, clauses: 1},
             %{kind: :def, name: :at_end, arity: 2, clauses: 1},
             %{kind: :def, name: :plain, arity: 1, clauses: 1}
           ]

    assert Enum.map(outer.unsupported, & &1.reason) == [
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :compile_annotation,
             :compile_annotation,
             :compile_annotation,
             :semantic_module_attribute,
             :compile_time_eval_attribute,
             :import,
             :struct_semantics,
             :exception_semantics,
             :record_semantics,
             :macro_definition,
             :module_level_generation,
             :module_level_generation,
             :guarded_definition,
             :nested_defmodule
           ]

    assert hd(outer.unsupported).attribute == :moduledoc

    assert Enum.map(Enum.take(outer.unsupported, 8), & &1.attribute) == [
             :moduledoc,
             :behaviour,
             :compile,
             :dialyzer,
             :impl,
             :compile,
             :dialyzer,
             :impl
           ]

    assert Enum.at(outer.unsupported, 8).attribute == :semantic_key
    assert Enum.at(outer.unsupported, 9).attribute == :digits

    assert Enum.map(inner.unsupported, & &1.reason) == [:require]
  end

  @tag :tmp_dir
  test "classifies module generation by reproducible AST structure", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "generation.ex"), """
    defmodule Generation do
      value = Enum.count([])
      if enabled(), do: :ok
      Enum.each([1], fn item -> defp generated(), do: item end)
      local_call(:value)
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)

    assert Enum.map(module.unsupported, fn entry ->
             {entry.generation_construct, entry.generation_root}
           end) == [
             {:module_match, "=/2"},
             {:generator_control, "if/2"},
             {:definition_generation, "Enum.each/2"},
             {:module_call, "local_call/1"}
           ]
  end

  @tag :tmp_dir
  test "builds a self-contained compile candidate only for eligible modules", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "eligible.ex"), """
    defmodule Eligible do
      @moduledoc false
      def double(value), do: value * 2
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.unsupported |> Enum.map(& &1.reason) == [:ignored_metadata]
    assert module.compile_source =~ "defmodule Eligible"
    assert module.compile_source =~ "def main do"
    assert module.compile_source =~ "@moduledoc false"

    assert module.compile_harness == %{
             original_forms: true,
             scope: "target-module-body",
             synthetic_main: true
           }

    assert %{"status" => "pass"} =
             CompileAttempt.run_source("eligible.ex", module.module, module.compile_source)
  end

  @tag :tmp_dir
  test "preserves target-module forms in order and excludes sibling scope", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "errors.ex"), """
    @file_level :excluded

    defmodule First do
      @moduledoc false
      @type value :: integer()
      @impl Access
      def value(), do: 1
    end

    defmodule Sibling do
      def sibling(), do: 2
    end
    """)

    assert [%{modules: [first, _sibling]}] = Inventory.discover!(tmp_dir)
    assert first.compile_source =~ "@moduledoc false"
    assert first.compile_source =~ "@type value :: integer()"
    assert first.compile_source =~ "@impl Access"
    assert first.compile_source =~ "def value()"
    assert first.compile_source =~ "def main do"
    refute first.compile_source =~ "@file_level"
    refute first.compile_source =~ "defmodule Sibling"

    assert ordered_forms(first.compile_source) == [
             "@moduledoc false",
             "@type value :: integer()",
             "@impl Access",
             "def value() do\n  1\nend",
             "def main do\n  0\nend"
           ]
  end

  @tag :tmp_dir
  test "does not duplicate an existing main entrypoint", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "main.ex"), """
    defmodule ExistingMain do
      @moduledoc false
      def main(), do: 7
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.compile_harness.synthetic_main == false

    assert Enum.count(ordered_forms(module.compile_source), &String.starts_with?(&1, "def main")) ==
             1
  end

  @tag :tmp_dir
  test "accepts only canonically normalized current-module exception schemas", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "schemas.ex"), """
    defmodule AcceptedError do
      @moduledoc false
      defexception [:message]
      def message(%{message: message}), do: message
    end

    defmodule StructOnly do
      defstruct [:value]
    end

    defmodule InvalidError do
      defexception message: dynamic_default()
    end

    defmodule DuplicateSchema do
      defexception [:message]
      defstruct [:value]
    end
    """)

    assert [%{modules: [accepted, struct, invalid, duplicate]}] = Inventory.discover!(tmp_dir)
    assert accepted.unsupported |> Enum.map(& &1.reason) == [:ignored_metadata]
    assert accepted.compile_source =~ "defexception [:message]"
    assert struct.unsupported |> Enum.map(& &1.reason) == [:struct_semantics]
    assert struct.compile_source == nil
    assert invalid.unsupported |> Enum.map(& &1.frontend_reason) == [:invalid_struct_schema]
    assert invalid.compile_source == nil

    assert duplicate.unsupported |> Enum.map(& &1.reason) == [
             :exception_semantics,
             :struct_semantics
           ]

    assert duplicate.compile_source == nil

    assert %{"status" => "pass"} =
             CompileAttempt.run_source("schemas.ex", accepted.module, accepted.compile_source)
  end

  test "requires complete canonical evidence for probe schema eligibility" do
    exception = schema_unsupported(:exception)
    struct = schema_unsupported(:struct)
    exception_snapshot = schema_snapshot(Fixture.Error, :exception)
    struct_snapshot = schema_snapshot(Fixture.Struct, :struct)

    assert Inventory.supported_current_module_schema?(
             exception,
             exception_snapshot,
             Fixture.Error,
             :exception
           )

    assert Inventory.supported_current_module_schema?(
             struct,
             struct_snapshot,
             Fixture.Struct,
             :struct
           )

    refute Inventory.supported_current_module_schema?(
             exception,
             exception_snapshot,
             Fixture.Other,
             :exception
           )

    refute Inventory.supported_current_module_schema?(
             exception,
             struct_snapshot,
             Fixture.Struct,
             :struct
           )

    refute Inventory.supported_current_module_schema?(
             %{exception | frontend_reason: :unknown_form},
             exception_snapshot,
             Fixture.Error,
             :exception
           )

    refute Inventory.supported_current_module_schema?(
             %{exception | reason: :struct_semantics},
             exception_snapshot,
             Fixture.Error,
             :exception
           )

    refute Inventory.supported_current_module_schema?(
             struct,
             %Batata.Frontend.Module{struct_snapshot | struct_schema: nil},
             Fixture.Struct,
             :struct
           )
  end

  @tag :tmp_dir
  test "records parse errors without crashing the whole inventory", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.ex"), "defmodule Broken do")

    assert [%{status: :parse_error, parse_error: parse_error}] = Inventory.discover!(tmp_dir)
    assert is_binary(parse_error.description)
  end

  @tag :tmp_dir
  test "uses frontend alias expansion without dropping other forms", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "sample.ex"), """
    defmodule Sample do
      alias Jason.Decoder
      def parse(input), do: Decoder.parse(input)
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.unsupported == []
    assert module.compile_source =~ "Jason.Decoder.parse(input)"
    refute module.compile_source =~ "alias "
  end

  @tag :tmp_dir
  test "keeps source definition counts while compiling expanded default arities", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "sample.ex"), """
    defmodule Sample do
      def parse(input, opts \\\\ []), do: {input, opts}
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.definitions == [%{kind: :def, name: :parse, arity: 2, clauses: 1}]
    assert module.unsupported == []
    assert module.compile_source =~ "def parse(batata_arg0)"
    assert module.compile_source =~ "def parse(input, opts)"
    refute module.compile_source =~ "\\\\"
  end

  @tag :tmp_dir
  test "known compile metadata shapes preserve BEAM results", %{tmp_dir: tmp_dir} do
    original = Path.join(tmp_dir, "original.exs")
    stripped = Path.join(tmp_dir, "stripped.exs")

    File.write!(original, """
    defmodule MetadataBehaviour do
      @callback value() :: integer()
    end

    defmodule MetadataFixture do
      @behaviour MetadataBehaviour
      @compile {:inline, value: 0}
      @dialyzer :no_improper_lists
      @impl true
      def value, do: 42
    end
    IO.write(MetadataFixture.value())
    """)

    File.write!(stripped, """
    defmodule MetadataBehaviour do
      @callback value() :: integer()
    end

    defmodule MetadataFixture do
      def value, do: 42
    end
    IO.write(MetadataFixture.value())
    """)

    assert {"42", 0} = System.cmd("elixir", [original], stderr_to_stdout: false)
    assert {"42", 0} = System.cmd("elixir", [stripped], stderr_to_stdout: false)
  end

  defp ordered_forms(source) do
    {:defmodule, _, [_name, [do: body]]} = Code.string_to_quoted!(source)

    body
    |> then(fn
      {:__block__, _, forms} -> forms
      form -> [form]
    end)
    |> Enum.map(&Macro.to_string/1)
  end

  defp schema_unsupported(:exception) do
    %{
      reason: :exception_semantics,
      frontend_reason: :accepted_as_definition,
      form_ast: quote(do: defexception([:message]))
    }
  end

  defp schema_unsupported(:struct) do
    %{
      reason: :struct_semantics,
      frontend_reason: :accepted_as_definition,
      form_ast: quote(do: defstruct([:value]))
    }
  end

  defp schema_snapshot(module, kind) do
    %Batata.Frontend.Module{
      name: module,
      definitions: [],
      struct_schema: %Batata.Frontend.StructSchema{module: module, kind: kind, fields: []}
    }
  end
end
