defmodule Batata.CompilerKernel.Native.ExConversion do
  # Target identifiers are private to the Batata artifact. The C adapter only
  # transports these AOT-produced encodings through Beaver's typed host table.
  def pattern_accept(actual_operands, actual_results, expected_operands, expected_results) do
    operands_match = actual_operands == expected_operands
    results_match = actual_results == expected_results
    Bitwise.band(operands_match, results_match)
  end

  def target_length(kind) do
    cond do
      kind == 1 -> 14
      kind == 2 -> 10
      kind == 3 -> 10
      kind == 4 -> 10
      kind == 5 -> 11
      kind == 6 -> 11
      kind == 7 -> 10
      kind == 8 -> 11
      kind == 9 -> 9
      true -> -1
    end
  end

  def target_word(kind, index) do
    cond do
      kind == 1 and index == 0 -> 0x74697261
      kind == 2 and index == 0 -> 0x74697261
      kind == 3 and index == 0 -> 0x74697261
      kind == 4 and index == 0 -> 0x74697261
      kind == 5 and index == 0 -> 0x74697261
      kind == 6 and index == 0 -> 0x74697261
      kind == 7 and index == 0 -> 0x74697261
      kind == 8 and index == 0 -> 0x74697261
      kind == 1 and index == 1 -> 0x6F632E68
      kind == 1 and index == 2 -> 0x6174736E
      kind == 1 and index == 3 -> 0x746E
      kind == 2 and index == 1 -> 0x64612E68
      kind == 2 and index == 2 -> 0x6964
      kind == 3 and index == 1 -> 0x75732E68
      kind == 3 and index == 2 -> 0x6962
      kind == 4 and index == 1 -> 0x756D2E68
      kind == 4 and index == 2 -> 0x696C
      kind == 5 and index == 1 -> 0x69642E68
      kind == 5 and index == 2 -> 0x697376
      kind == 6 and index == 1 -> 0x65722E68
      kind == 6 and index == 2 -> 0x69736D
      kind == 7 and index == 1 -> 0x6D632E68
      kind == 7 and index == 2 -> 0x6970
      kind == 8 and index == 1 -> 0x78652E68
      kind == 8 and index == 2 -> 0x697574
      kind == 9 and index == 0 -> 0x2E666373
      kind == 9 and index == 1 -> 0x6C656979
      kind == 9 and index == 2 -> 0x64
      true -> -1
    end
  end

  def cmp_predicate(length, word) do
    cond do
      length == 2 and word == 0x7165 -> 0
      length == 2 and word == 0x656E -> 1
      length == 3 and word == 0x746C73 -> 2
      length == 3 and word == 0x656C73 -> 3
      length == 3 and word == 0x746773 -> 4
      length == 3 and word == 0x656773 -> 5
      length == 3 and word == 0x746C75 -> 6
      length == 3 and word == 0x656C75 -> 7
      length == 3 and word == 0x746775 -> 8
      length == 3 and word == 0x656775 -> 9
      true -> -1
    end
  end
end
