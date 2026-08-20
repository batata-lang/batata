defmodule Batata.Frontend.UnicodeEscapeMacroExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  @source """
  defmodule UnicodeConsumer do
    defmodule Unescape do
      @digits Enum.concat([?0..?9, ?A..?F, ?a..?f])

      def unicode_escapes(chars1 \\\\ @digits, chars2 \\\\ @digits) do
        for char1 <- chars1, char2 <- chars2, do: {char1, char2}
      end

      defmacro escapeu_first(int, last, rest, original, skip, stack, decode, acc) do
        clauses = escapeu_first_clauses(last, rest, original, skip, stack, decode, acc)
        quote(do: case(unquote(int), do: unquote(clauses)))
      end

      defmacro escapeu_last(int, original, skip) do
        clauses = escapeu_last_clauses()
        quote(do: case(unquote(int), do: unquote(clauses)))
      end

      defmacro escapeu_surrogate(int, last, rest, original, skip, stack, decode, acc, hi) do
        clauses = escapeu_surrogate_clauses(last, rest, original, skip, stack, decode, acc, hi)
        quote(do: case(unquote(int), do: unquote(clauses)))
      end
    end

    def last() do
      require Unescape
      Unescape.escapeu_last(0x3031, <<>>, 0)
    end

    def first(int, last, rest, original, skip, stack, decode, acc) do
      require Unescape
      Unescape.escapeu_first(int, last, rest, original, skip, stack, decode, acc)
    end

    def surrogate(int, last, rest, original, skip, stack, decode, acc, hi) do
      require Unescape
      Unescape.escapeu_surrogate(int, last, rest, original, skip, stack, decode, acc, hi)
    end
  end
  """

  test "removes the nested provider and expands bounded case tables" do
    snapshot = Frontend.from_source(@source)

    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:last, :first, :surrogate]

    last = Enum.find(snapshot.definitions, &(&1.name == :last))
    {:case, _, [_literal, [do: last_clauses]]} = hd(last.clauses).body_ast
    assert {:->, _, [[0x3031], 1]} = Enum.find(last_clauses, &match?({:->, _, [[0x3031], _]}, &1))
    assert length(last_clauses) == 485

    decoded =
      Map.new(Enum.drop(last_clauses, -1), fn {:->, _, [[raw], value]} -> {raw, value} end)

    assert map_size(decoded) == 484
    assert decoded[0x3030] == 0
    assert decoded[0x4646] == 255
    assert decoded[0x6666] == 255

    first = Enum.find(snapshot.definitions, &(&1.name == :first))
    {:case, _, [_int, [do: first_clauses]]} = hd(first.clauses).body_ast
    assert length(first_clauses) == 469

    surrogate = Enum.find(snapshot.definitions, &(&1.name == :surrogate))
    {:case, _, [_int, [do: surrogate_clauses]]} = hd(surrogate.clauses).body_ast
    assert length(surrogate_clauses) == 17
  end

  test "leaves unrelated nested modules unsupported" do
    snapshot =
      Frontend.from_source("defmodule Outer do defmodule Inner do def value(), do: 1 end end")

    assert [%Frontend.UnsupportedForm{reason: :nested_defmodule}] = snapshot.unsupported
  end
end
