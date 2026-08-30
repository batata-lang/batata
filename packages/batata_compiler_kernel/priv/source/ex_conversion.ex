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
      kind == 10 -> 9
      kind == 11 -> 10
      kind == 12 -> 19
      kind == 13 -> 17
      kind == 14 -> 24
      kind == 15 -> 12
      kind == 16 -> 6
      kind == 17 -> 11
      kind == 18 -> 9
      kind == 19 -> 22
      kind == 20 -> 21
      kind == 21 -> 21
      kind == 22 -> 23
      kind == 23 -> 21
      kind == 24 -> 22
      kind == 25 -> 24
      kind == 26 -> 24
      kind == 27 -> 29
      kind == 28 -> 31
      kind == 29 -> 24
      kind == 30 -> 24
      kind == 31 -> 26
      kind == 32 -> 23
      kind == 33 -> 14
      kind == 34 -> 14
      kind == 35 -> 22
      kind == 36 -> 24
      kind == 37 -> 23
      kind == 38 -> 20
      kind == 39 -> 21
      kind == 40 -> 22
      kind == 41 -> 27
      kind == 42 -> 12
      kind == 43 -> 12
      kind == 44 -> 15
      kind == 45 -> 21
      kind == 46 -> 13
      kind == 47 -> 21
      kind == 48 -> 21
      kind == 49 -> 20
      kind == 50 -> 20
      kind == 51 -> 27
      kind == 52 -> 25
      kind == 53 -> 12
      kind == 54 -> 14
      kind == 55 -> 12
      kind == 56 -> 15
      kind == 57 -> 17
      kind == 58 -> 26
      kind == 59 -> 22
      kind == 60 -> 17
      kind == 61 -> 25
      kind == 62 -> 20
      kind == 63 -> 19
      kind == 64 -> 18
      kind == 65 -> 21
      kind == 66 -> 21
      kind == 67 -> 24
      kind == 68 -> 18
      kind == 69 -> 18
      kind == 70 -> 18
      kind == 71 -> 19
      kind == 72 -> 20
      kind == 73 -> 22
      kind == 74 -> 11
      kind == 75 -> 22
      kind == 76 -> 21
      kind == 77 -> 25
      kind == 78 -> 19
      kind == 79 -> 22
      kind == 80 -> 14
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
      kind == 10 and index == 0 -> 0x636E7566
      kind == 10 and index == 1 -> 0x6C61632E
      kind == 10 and index == 2 -> 0x6C
      kind == 11 and index == 0 -> 0x742E7865
      kind == 11 and index == 1 -> 0x2E6D7265
      kind == 11 and index == 2 -> 0x7165
      kind == 12 and index == 0 -> 0x742E7865
      kind == 12 and index == 1 -> 0x2E6D7265
      kind == 12 and index == 2 -> 0x616E6962
      kind == 12 and index == 3 -> 0x705F7972
      kind == 12 and index == 4 -> 0x747261
      kind == 13 and index == 0 -> 0x742E7865
      kind == 13 and index == 1 -> 0x2E6D7265
      kind == 13 and index == 2 -> 0x7473696C
      kind == 13 and index == 3 -> 0x6E6F635F
      kind == 13 and index == 4 -> 0x73
      kind == 14 and index == 0 -> 0x742E7865
      kind == 14 and index == 1 -> 0x2E6D7265
      kind == 14 and index == 2 -> 0x616E6962
      kind == 14 and index == 3 -> 0x665F7972
      kind == 14 and index == 4 -> 0x5F6D6F72
      kind == 14 and index == 5 -> 0x7473696C
      kind == 15 and index == 0 -> 0x74697261
      kind == 15 and index == 1 -> 0x72742E68
      kind == 15 and index == 2 -> 0x69636E75
      kind == 16 and index == 0 -> 0x2E666373
      kind == 16 and index == 1 -> 0x6669
      kind == 17 and index == 0 -> 0x636E7566
      kind == 17 and index == 1 -> 0x7465722E
      kind == 17 and index == 2 -> 0x6E7275
      kind == 18 and index == 0 -> 0x636E7566
      kind == 18 and index == 1 -> 0x6E75662E
      kind == 18 and index == 2 -> 0x63
      kind == 19 and index == 0 -> 0x742E7865
      kind == 19 and index == 1 -> 0x2E6D7265
      kind == 19 and index == 2 -> 0x746E7572
      kind == 19 and index == 3 -> 0x5F656D69
      kind == 19 and index == 4 -> 0x61657263
      kind == 19 and index == 5 -> 0x6574
      kind == 20 and index == 0 -> 0x742E7865
      kind == 20 and index == 1 -> 0x2E6D7265
      kind == 20 and index == 2 -> 0x746E7572
      kind == 20 and index == 3 -> 0x5F656D69
      kind == 20 and index == 4 -> 0x65746E65
      kind == 20 and index == 5 -> 0x72
      kind == 21 and index == 0 -> 0x742E7865
      kind == 21 and index == 1 -> 0x2E6D7265
      kind == 21 and index == 2 -> 0x746E7572
      kind == 21 and index == 3 -> 0x5F656D69
      kind == 21 and index == 4 -> 0x7661656C
      kind == 21 and index == 5 -> 0x65
      kind == 22 and index == 0 -> 0x742E7865
      kind == 22 and index == 1 -> 0x2E6D7265
      kind == 22 and index == 2 -> 0x746E7572
      kind == 22 and index == 3 -> 0x5F656D69
      kind == 22 and index == 4 -> 0x74736564
      kind == 22 and index == 5 -> 0x796F72
      kind == 23 and index == 0 -> 0x742E7865
      kind == 23 and index == 1 -> 0x2E6D7265
      kind == 23 and index == 2 -> 0x75736572
      kind == 23 and index == 3 -> 0x635F746C
      kind == 23 and index == 4 -> 0x74616572
      kind == 23 and index == 5 -> 0x65
      kind == 24 and index == 0 -> 0x742E7865
      kind == 24 and index == 1 -> 0x2E6D7265
      kind == 24 and index == 2 -> 0x75736572
      kind == 24 and index == 3 -> 0x645F746C
      kind == 24 and index == 4 -> 0x72747365
      kind == 24 and index == 5 -> 0x796F
      kind == 25 and index == 0 -> 0x742E7865
      kind == 25 and index == 1 -> 0x2E6D7265
      kind == 25 and index == 2 -> 0x75736572
      kind == 25 and index == 3 -> 0x725F746C
      kind == 25 and index == 4 -> 0x5F746F6F
      kind == 25 and index == 5 -> 0x646E696B
      kind == 26 and index == 0 -> 0x742E7865
      kind == 26 and index == 1 -> 0x2E6D7265
      kind == 26 and index == 2 -> 0x75736572
      kind == 26 and index == 3 -> 0x725F746C
      kind == 26 and index == 4 -> 0x5F746F6F
      kind == 26 and index == 5 -> 0x64726F77
      kind == 27 and index == 0 -> 0x742E7865
      kind == 27 and index == 1 -> 0x2E6D7265
      kind == 27 and index == 2 -> 0x75736572
      kind == 27 and index == 3 -> 0x655F746C
      kind == 27 and index == 4 -> 0x70656378
      kind == 27 and index == 5 -> 0x6E6F6974
      kind == 27 and index == 6 -> 0x6E696B5F
      kind == 27 and index == 7 -> 0x64
      kind == 28 and index == 0 -> 0x742E7865
      kind == 28 and index == 1 -> 0x2E6D7265
      kind == 28 and index == 2 -> 0x75736572
      kind == 28 and index == 3 -> 0x655F746C
      kind == 28 and index == 4 -> 0x70656378
      kind == 28 and index == 5 -> 0x6E6F6974
      kind == 28 and index == 6 -> 0x6165725F
      kind == 28 and index == 7 -> 0x6E6F73
      kind == 29 and index == 0 -> 0x742E7865
      kind == 29 and index == 1 -> 0x2E6D7265
      kind == 29 and index == 2 -> 0x75736572
      kind == 29 and index == 3 -> 0x745F746C
      kind == 29 and index == 4 -> 0x5F6D7265
      kind == 29 and index == 5 -> 0x646E696B
      kind == 30 and index == 0 -> 0x742E7865
      kind == 30 and index == 1 -> 0x2E6D7265
      kind == 30 and index == 2 -> 0x75736572
      kind == 30 and index == 3 -> 0x615F746C
      kind == 30 and index == 4 -> 0x5F6D6F74
      kind == 30 and index == 5 -> 0x656D616E
      kind == 31 and index == 0 -> 0x742E7865
      kind == 31 and index == 1 -> 0x2E6D7265
      kind == 31 and index == 2 -> 0x75736572
      kind == 31 and index == 3 -> 0x745F746C
      kind == 31 and index == 4 -> 0x5F6D7265
      kind == 31 and index == 5 -> 0x676E656C
      kind == 31 and index == 6 -> 0x6874
      kind == 32 and index == 0 -> 0x742E7865
      kind == 32 and index == 1 -> 0x2E6D7265
      kind == 32 and index == 2 -> 0x75736572
      kind == 32 and index == 3 -> 0x745F746C
      kind == 32 and index == 4 -> 0x5F6D7265
      kind == 32 and index == 5 -> 0x746567
      kind == 33 and index == 0 -> 0x742E7865
      kind == 33 and index == 1 -> 0x2E6D7265
      kind == 33 and index == 2 -> 0x6F707865
      kind == 33 and index == 3 -> 0x7472
      kind == 34 and index == 0 -> 0x742E7865
      kind == 34 and index == 1 -> 0x2E6D7265
      kind == 34 and index == 2 -> 0x6F706D69
      kind == 34 and index == 3 -> 0x7472
      kind == 35 and index == 0 -> 0x742E7865
      kind == 35 and index == 1 -> 0x2E6D7265
      kind == 35 and index == 2 -> 0x6F707865
      kind == 35 and index == 3 -> 0x64657472
      kind == 35 and index == 4 -> 0x6F6C635F
      kind == 35 and index == 5 -> 0x656E
      kind == 36 and index == 0 -> 0x742E7865
      kind == 36 and index == 1 -> 0x2E6D7265
      kind == 36 and index == 2 -> 0x6F707865
      kind == 36 and index == 3 -> 0x64657472
      kind == 36 and index == 4 -> 0x7365645F
      kind == 36 and index == 5 -> 0x796F7274
      kind == 37 and index == 0 -> 0x742E7865
      kind == 37 and index == 1 -> 0x2E6D7265
      kind == 37 and index == 2 -> 0x6F707865
      kind == 37 and index == 3 -> 0x64657472
      kind == 37 and index == 4 -> 0x6E656C5F
      kind == 37 and index == 5 -> 0x687467
      kind == 38 and index == 0 -> 0x742E7865
      kind == 38 and index == 1 -> 0x2E6D7265
      kind == 38 and index == 2 -> 0x6F707865
      kind == 38 and index == 3 -> 0x64657472
      kind == 38 and index == 4 -> 0x7465675F
      kind == 39 and index == 0 -> 0x742E7865
      kind == 39 and index == 1 -> 0x2E6D7265
      kind == 39 and index == 2 -> 0x646E6168
      kind == 39 and index == 3 -> 0x655F656C
      kind == 39 and index == 4 -> 0x726F7078
      kind == 39 and index == 5 -> 0x74
      kind == 40 and index == 0 -> 0x742E7865
      kind == 40 and index == 1 -> 0x2E6D7265
      kind == 40 and index == 2 -> 0x646E6168
      kind == 40 and index == 3 -> 0x645F656C
      kind == 40 and index == 4 -> 0x72747365
      kind == 40 and index == 5 -> 0x796F
      kind == 41 and index == 0 -> 0x742E7865
      kind == 41 and index == 1 -> 0x2E6D7265
      kind == 41 and index == 2 -> 0x636F7270
      kind == 41 and index == 3 -> 0x5F737365
      kind == 41 and index == 4 -> 0x6C626174
      kind == 41 and index == 5 -> 0x65725F65
      kind == 41 and index == 6 -> 0x746573
      kind >= 42 and kind <= 80 and index == 0 -> 0x742E7865
      kind >= 42 and kind <= 80 and index == 1 -> 0x2E6D7265
      kind == 42 and index == 2 -> 0x666C6573
      kind == 43 and index == 2 -> 0x646E6573
      kind == 44 and index == 2 -> 0x65636572
      kind == 44 and index == 3 -> 0x657669
      kind == 45 and index == 2 -> 0x6C69616D
      kind == 45 and index == 3 -> 0x5F786F62
      kind == 45 and index == 4 -> 0x61656C63
      kind == 45 and index == 5 -> 0x72
      kind == 46 and index == 2 -> 0x77617073
      kind == 46 and index == 3 -> 0x6E
      kind == 47 and index == 2 -> 0x65686373
      kind == 47 and index == 3 -> 0x656C7564
      kind == 47 and index == 4 -> 0x78656E5F
      kind == 47 and index == 5 -> 0x74
      kind == 48 and index == 2 -> 0x72727563
      kind == 48 and index == 3 -> 0x5F746E65
      kind == 48 and index == 4 -> 0x72746E65
      kind == 48 and index == 5 -> 0x79
      kind == 49 and index == 2 -> 0x636F7270
      kind == 49 and index == 3 -> 0x5F737365
      kind == 49 and index == 4 -> 0x656E6F64
      kind == 50 and index == 2 -> 0x636F7270
      kind == 50 and index == 3 -> 0x5F737365
      kind == 50 and index == 4 -> 0x74697865
      kind == 51 and index == 2 -> 0x636F7270
      kind == 51 and index == 3 -> 0x5F737365
      kind == 51 and index == 4 -> 0x74697865
      kind == 51 and index == 5 -> 0x6165725F
      kind == 51 and index == 6 -> 0x6E6F73
      kind == 52 and index == 2 -> 0x636F7270
      kind == 52 and index == 3 -> 0x5F737365
      kind == 52 and index == 4 -> 0x70617274
      kind == 52 and index == 5 -> 0x6978655F
      kind == 52 and index == 6 -> 0x74
      kind == 53 and index == 2 -> 0x6B6E696C
      kind == 54 and index == 2 -> 0x696C6E75
      kind == 54 and index == 3 -> 0x6B6E
      kind == 55 and index == 2 -> 0x74697865
      kind == 56 and index == 2 -> 0x696E6F6D
      kind == 56 and index == 3 -> 0x726F74
      kind == 57 and index == 2 -> 0x6F6D6564
      kind == 57 and index == 3 -> 0x6F74696E
      kind == 57 and index == 4 -> 0x72
      kind == 58 and index == 2 -> 0x636F7270
      kind == 58 and index == 3 -> 0x65737365
      kind == 58 and index == 4 -> 0x75725F73
      kind == 58 and index == 5 -> 0x62616E6E
      kind == 58 and index == 6 -> 0x656C
      kind == 59 and index == 2 -> 0x636F7270
      kind == 59 and index == 3 -> 0x5F737365
      kind == 59 and index == 4 -> 0x75736572
      kind == 59 and index == 5 -> 0x746C
      kind == 60 and index == 2 -> 0x746E6F63
      kind == 60 and index == 3 -> 0x7661735F
      kind == 60 and index == 4 -> 0x65
      kind == 61 and index == 2 -> 0x65636572
      kind == 61 and index == 3 -> 0x5F657669
      kind == 61 and index == 4 -> 0x746E6F63
      kind == 61 and index == 5 -> 0x7661735F
      kind == 61 and index == 6 -> 0x65
      kind == 62 and index == 2 -> 0x746E6F63
      kind == 62 and index == 3 -> 0x6E65705F
      kind == 62 and index == 4 -> 0x676E6964
      kind == 63 and index == 2 -> 0x746E6F63
      kind == 63 and index == 3 -> 0x7463615F
      kind == 63 and index == 4 -> 0x657669
      kind == 64 and index == 2 -> 0x746E6F63
      kind == 64 and index == 3 -> 0x656C635F
      kind == 64 and index == 4 -> 0x7261
      kind == 65 and index == 2 -> 0x746E6F63
      kind == 65 and index == 3 -> 0x616F6C5F
      kind == 65 and index == 4 -> 0x72615F64
      kind == 65 and index == 5 -> 0x67
      kind == 66 and index == 2 -> 0x746E6F63
      kind == 66 and index == 3 -> 0x616F6C5F
      kind == 66 and index == 4 -> 0x63615F64
      kind == 66 and index == 5 -> 0x63
      kind == 67 and index == 2 -> 0x746E6F63
      kind == 67 and index == 3 -> 0x616F6C5F
      kind == 67 and index == 4 -> 0x75635F64
      kind == 67 and index == 5 -> 0x726F7372
      kind == 68 and index == 2 -> 0x636F6C63
      kind == 68 and index == 3 -> 0x6E695F6B
      kind == 68 and index == 4 -> 0x7469
      kind == 69 and index == 2 -> 0x636F6C63
      kind == 69 and index == 3 -> 0x69745F6B
      kind == 69 and index == 4 -> 0x6B63
      kind == 70 and index == 2 -> 0x6C656979
      kind == 70 and index == 3 -> 0x616D5F64
      kind == 70 and index == 4 -> 0x6B72
      kind == 71 and index == 2 -> 0x6C69616D
      kind == 71 and index == 3 -> 0x5F786F62
      kind == 71 and index == 4 -> 0x6E656C
      kind == 72 and index == 2 -> 0x6C69616D
      kind == 72 and index == 3 -> 0x5F786F62
      kind == 72 and index == 4 -> 0x6B656570
      kind == 73 and index == 2 -> 0x6C69616D
      kind == 73 and index == 3 -> 0x5F786F62
      kind == 73 and index == 4 -> 0x6F6D6572
      kind == 73 and index == 5 -> 0x6576
      kind == 74 and index == 2 -> 0x6C696E
      kind == 75 and index == 2 -> 0x6F6E6F6D
      kind == 75 and index == 3 -> 0x696E6F74
      kind == 75 and index == 4 -> 0x69745F63
      kind == 75 and index == 5 -> 0x656D
      kind == 76 and index == 2 -> 0x65636572
      kind == 76 and index == 3 -> 0x5F657669
      kind == 76 and index == 4 -> 0x72617473
      kind == 76 and index == 5 -> 0x74
      kind == 77 and index == 2 -> 0x65636572
      kind == 77 and index == 3 -> 0x5F657669
      kind == 77 and index == 4 -> 0x72617473
      kind == 77 and index == 5 -> 0x65735F74
      kind == 77 and index == 6 -> 0x74
      kind == 78 and index == 2 -> 0x6974616E
      kind == 78 and index == 3 -> 0x745F6576
      kind == 78 and index == 4 -> 0x656D69
      kind == 79 and index == 2 -> 0x71696E75
      kind == 79 and index == 3 -> 0x695F6575
      kind == 79 and index == 4 -> 0x6765746E
      kind == 79 and index == 5 -> 0x7265
      kind == 80 and index == 2 -> 0x695F6F74
      kind == 80 and index == 3 -> 0x746E
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

  def runtime_arity(kind) do
    cond do
      kind == 11 -> 2
      kind == 12 -> 3
      kind == 13 -> 2
      kind == 14 -> 1
      kind == 19 -> 0
      kind == 20 -> 1
      kind == 21 -> 0
      kind == 22 -> 1
      kind == 23 -> 2
      kind == 24 -> 1
      kind == 25 -> 1
      kind == 26 -> 1
      kind == 27 -> 1
      kind == 28 -> 1
      kind == 29 -> 2
      kind == 30 -> 2
      kind == 31 -> 2
      kind == 32 -> 3
      kind == 33 -> 2
      kind == 34 -> 2
      kind == 35 -> 1
      kind == 36 -> 1
      kind == 37 -> 1
      kind == 38 -> 2
      kind == 39 -> 1
      kind == 40 -> 1
      kind == 41 -> 1
      kind == 42 -> 0
      kind == 43 -> 2
      kind == 44 -> 0
      kind == 45 -> 0
      kind == 46 -> 1
      kind == 47 -> 0
      kind == 48 -> 0
      kind == 49 -> 1
      kind == 50 -> 1
      kind == 51 -> 1
      kind == 52 -> 1
      kind == 53 -> 3
      kind == 54 -> 1
      kind == 55 -> 4
      kind == 56 -> 4
      kind == 57 -> 1
      kind == 58 -> 0
      kind == 59 -> 1
      kind == 60 -> 3
      kind == 61 -> 3
      kind == 62 -> 0
      kind == 63 -> 0
      kind == 64 -> 0
      kind == 65 -> 0
      kind == 66 -> 0
      kind == 67 -> 0
      kind == 68 -> 1
      kind == 69 -> 1
      kind == 70 -> 0
      kind == 71 -> 0
      kind == 72 -> 1
      kind == 73 -> 1
      kind == 74 -> 0
      kind == 75 -> 0
      kind == 76 -> 0
      kind == 77 -> 1
      kind == 78 -> 0
      kind == 79 -> 1
      kind == 80 -> 1
      true -> -1
    end
  end

  def structural_limit(kind) do
    cond do
      kind == 1 -> 8
      kind == 2 -> 2
      true -> -1
    end
  end
end
