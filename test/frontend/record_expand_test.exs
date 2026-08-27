defmodule Batata.Frontend.RecordExpandTest do
  use ExUnit.Case, async: true, group: :execution_engine

  alias Batata.Frontend
  alias Beaver.MLIR.Context

  test "expands private record construction, matching, and access end to end" do
    source = """
    defmodule RecordDemo do
      import Record
      defrecordp :state, count: 0, label: nil

      def main() do
        record = state(count: 4, label: :ok)
        state(label: label) = record

        if label == :ok do
          {state(record, :count), label}
        else
          {0, label}
        end
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Batata.execute(source, Context.create()) == {4, :ok}
  end

  test "expands record updates into bounded tuple updates" do
    snapshot =
      Frontend.from_source("""
      defmodule RecordDemo do
        import Record
        defrecordp :state, count: 0, label: nil

        def changed(record), do: state(record, count: 7)
      end
      """)

    assert snapshot.unsupported == []
    changed = Enum.find(snapshot.definitions, &(&1.name == :changed))
    assert Macro.to_string(hd(changed.clauses).body_ast) == "put_elem(record, 1, 7)"
  end

  test "keeps Record imports without a supported declaration visible" do
    snapshot =
      Frontend.from_source("""
      defmodule RecordDemo do
        import Record
        def value(), do: 1
      end
      """)

    assert [%Frontend.UnsupportedForm{reason: :import}] = snapshot.unsupported
  end
end
