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
      kind == 81 -> 16
      kind == 82 -> 20
      kind == 83 -> 17
      kind == 84 -> 17
      kind == 85 -> 16
      kind == 86 -> 19
      kind == 87 -> 17
      kind == 88 -> 20
      kind == 89 -> 17
      kind == 90 -> 15
      kind == 91 -> 18
      kind == 92 -> 24
      kind == 93 -> 21
      kind == 94 -> 18
      kind == 96 -> 24
      kind == 97 -> 17
      kind == 98 -> 23
      kind == 99 -> 22
      kind == 100 -> 31
      kind == 101 -> 29
      kind == 102 -> 21
      kind == 103 -> 18
      kind == 104 -> 20
      kind == 105 -> 23
      kind == 106 -> 25
      kind == 107 -> 26
      kind == 108 -> 24
      kind == 109 -> 20
      kind == 110 -> 23
      kind == 111 -> 23
      kind == 112 -> 21
      kind == 113 -> 26
      kind == 114 -> 18
      kind == 115 -> 21
      kind == 116 -> 17
      kind == 117 -> 23
      kind == 118 -> 24
      kind == 119 -> 26
      kind == 120 -> 27
      kind == 121 -> 30
      kind == 122 -> 32
      kind == 123 -> 25
      kind == 124 -> 27
      kind == 125 -> 31
      kind == 126 -> 29
      kind == 127 -> 26
      kind == 128 -> 31
      kind == 129 -> 33
      kind == 130 -> 36
      kind == 131 -> 21
      kind == 132 -> 19
      kind == 133 -> 19
      kind == 134 -> 17
      kind == 135 -> 23
      kind == 136 -> 20
      kind == 137 -> 18
      kind == 138 -> 19
      kind == 139 -> 13
      kind == 140 -> 13
      kind == 141 -> 10
      kind == 142 -> 18
      kind == 143 -> 16
      kind == 144 -> 15
      kind == 145 -> 17
      kind == 146 -> 15
      kind == 147 -> 16
      kind == 148 -> 14
      kind == 150 -> 23
      kind == 151 -> 21
      kind == 152 -> 16
      kind == 153 -> 27
      kind == 154 -> 31
      kind == 155 -> 15
      kind == 156 -> 15
      kind == 157 -> 13
      kind == 158 -> 13
      kind == 159 -> 11
      kind == 160 -> 13
      kind == 161 -> 9
      kind == 162 -> 20
      kind == 163 -> 16
      kind == 164 -> 19
      kind == 165 -> 15
      kind == 201 -> 5
      kind == 202 -> 9
      kind == 203 -> 6
      kind == 204 -> 5
      kind == 205 -> 8
      kind == 206 -> 6
      kind == 207 -> 7
      kind == 208 -> 11
      kind == 209 -> 9
      kind == 210 -> 13
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
      kind >= 81 and kind <= 135 and index == 0 -> 0x742E7865
      kind >= 81 and kind <= 135 and index == 1 -> 0x2E6D7265
      kind == 81 and index == 2 -> 0x6C5F7165
      kind == 81 and index == 3 -> 0x65736F6F
      kind == 82 and index == 2 -> 0x7473696C
      kind == 82 and index == 3 -> 0x616C665F
      kind == 82 and index == 4 -> 0x6E657474
      kind == 83 and index == 2 -> 0x7473696C
      kind == 83 and index == 3 -> 0x6165685F
      kind == 83 and index == 4 -> 0x64
      kind == 84 and index == 2 -> 0x7473696C
      kind == 84 and index == 3 -> 0x6961745F
      kind == 84 and index == 4 -> 0x6C
      kind == 85 and index == 2 -> 0x7473696C
      kind == 85 and index == 3 -> 0x7465675F
      kind == 86 and index == 2 -> 0x7473696C
      kind == 86 and index == 3 -> 0x6E656C5F
      kind == 86 and index == 4 -> 0x687467
      kind == 87 and index == 2 -> 0x6C707574
      kind == 87 and index == 3 -> 0x65675F65
      kind == 87 and index == 4 -> 0x74
      kind == 88 and index == 2 -> 0x6C707574
      kind == 88 and index == 3 -> 0x656C5F65
      kind == 88 and index == 4 -> 0x6874676E
      kind == 89 and index == 2 -> 0x5F70616D
      kind == 89 and index == 3 -> 0x63746566
      kind == 89 and index == 4 -> 0x68
      kind == 90 and index == 2 -> 0x5F70616D
      kind == 90 and index == 3 -> 0x747570
      kind == 91 and index == 2 -> 0x5F70616D
      kind == 91 and index == 3 -> 0x676E656C
      kind == 91 and index == 4 -> 0x6874
      kind == 92 and index == 2 -> 0x7370616D
      kind == 92 and index == 3 -> 0x665F7465
      kind == 92 and index == 4 -> 0x5F6D6F72
      kind == 92 and index == 5 -> 0x7473696C
      kind == 93 and index == 2 -> 0x7370616D
      kind == 93 and index == 3 -> 0x6D5F7465
      kind == 93 and index == 4 -> 0x65626D65
      kind == 93 and index == 5 -> 0x72
      kind == 94 and index == 2 -> 0x7370616D
      kind == 94 and index == 3 -> 0x705F7465
      kind == 94 and index == 4 -> 0x7475
      kind == 96 and index == 2 -> 0x61646F69
      kind == 96 and index == 3 -> 0x745F6174
      kind == 96 and index == 4 -> 0x69625F6F
      kind == 96 and index == 5 -> 0x7972616E
      kind == 97 and index == 2 -> 0x616F6C66
      kind == 97 and index == 3 -> 0x696C5F74
      kind == 97 and index == 4 -> 0x74
      kind == 98 and index == 2 -> 0x69727473
      kind == 98 and index == 3 -> 0x745F676E
      kind == 98 and index == 4 -> 0x6C665F6F
      kind == 98 and index == 5 -> 0x74616F
      kind == 99 and index == 2 -> 0x69727473
      kind == 99 and index == 3 -> 0x745F676E
      kind == 99 and index == 4 -> 0x74615F6F
      kind == 99 and index == 5 -> 0x6D6F
      kind == 100 and index == 2 -> 0x69727473
      kind == 100 and index == 3 -> 0x745F676E
      kind == 100 and index == 4 -> 0x78655F6F
      kind == 100 and index == 5 -> 0x69747369
      kind == 100 and index == 6 -> 0x615F676E
      kind == 100 and index == 7 -> 0x6D6F74
      kind == 101 and index == 2 -> 0x616F6C66
      kind == 101 and index == 3 -> 0x6F745F74
      kind == 101 and index == 4 -> 0x6E69625F
      kind == 101 and index == 5 -> 0x5F797261
      kind == 101 and index == 6 -> 0x726F6873
      kind == 101 and index == 7 -> 0x74
      kind == 102 and index == 2 -> 0x616E6962
      kind == 102 and index == 3 -> 0x6C5F7972
      kind == 102 and index == 4 -> 0x74676E65
      kind == 102 and index == 5 -> 0x68
      kind == 103 and index == 2 -> 0x616E6962
      kind == 103 and index == 3 -> 0x675F7972
      kind == 103 and index == 4 -> 0x7465
      kind == 104 and index == 2 -> 0x616E6962
      kind == 104 and index == 3 -> 0x735F7972
      kind == 104 and index == 4 -> 0x6563696C
      kind == 105 and index == 2 -> 0x616E6962
      kind == 105 and index == 3 -> 0x755F7972
      kind == 105 and index == 4 -> 0x5F386674
      kind == 105 and index == 5 -> 0x746567
      kind == 106 and index == 2 -> 0x616E6962
      kind == 106 and index == 3 -> 0x755F7972
      kind == 106 and index == 4 -> 0x5F386674
      kind == 106 and index == 5 -> 0x74646977
      kind == 106 and index == 6 -> 0x68
      kind == 107 and index == 2 -> 0x616E6962
      kind == 107 and index == 3 -> 0x755F7972
      kind == 107 and index == 4 -> 0x5F386674
      kind == 107 and index == 5 -> 0x676E656C
      kind == 107 and index == 6 -> 0x6874
      kind == 108 and index == 2 -> 0x69727473
      kind == 108 and index == 3 -> 0x705F676E
      kind == 108 and index == 4 -> 0x746E6972
      kind == 108 and index == 5 -> 0x656C6261
      kind == 109 and index == 2 -> 0x616E6962
      kind == 109 and index == 3 -> 0x715F7972
      kind == 109 and index == 4 -> 0x65746F75
      kind == 110 and index == 2 -> 0x616E6962
      kind == 110 and index == 3 -> 0x655F7972
      kind == 110 and index == 4 -> 0x646F636E
      kind == 110 and index == 5 -> 0x363165
      kind == 111 and index == 2 -> 0x616E6962
      kind == 111 and index == 3 -> 0x645F7972
      kind == 111 and index == 4 -> 0x646F6365
      kind == 111 and index == 5 -> 0x363165
      kind == 112 and index == 2 -> 0x5F746E69
      kind == 112 and index == 3 -> 0x735F6F74
      kind == 112 and index == 4 -> 0x6E697274
      kind == 112 and index == 5 -> 0x67
      kind == 113 and index == 2 -> 0x5F746E69
      kind == 113 and index == 3 -> 0x735F6F74
      kind == 113 and index == 4 -> 0x6E697274
      kind == 113 and index == 5 -> 0x61625F67
      kind == 113 and index == 6 -> 0x6573
      kind == 114 and index == 2 -> 0x5F746E69
      kind == 114 and index == 3 -> 0x685F6F74
      kind == 114 and index == 4 -> 0x7865
      kind == 115 and index == 2 -> 0x69727473
      kind == 115 and index == 3 -> 0x745F676E
      kind == 115 and index == 4 -> 0x6E695F6F
      kind == 115 and index == 5 -> 0x74
      kind == 116 and index == 2 -> 0x656C6966
      kind == 116 and index == 3 -> 0x6165725F
      kind == 116 and index == 4 -> 0x64
      kind == 117 and index == 2 -> 0x656C6966
      kind == 117 and index == 3 -> 0x6165725F
      kind == 117 and index == 4 -> 0x696C5F64
      kind == 117 and index == 5 -> 0x73656E
      kind == 118 and index == 2 -> 0x6D756E65
      kind == 118 and index == 3 -> 0x62617265
      kind == 118 and index == 4 -> 0x635F656C
      kind == 118 and index == 5 -> 0x746E756F
      kind == 119 and index == 2 -> 0x6D756E65
      kind == 119 and index == 3 -> 0x62617265
      kind == 119 and index == 4 -> 0x745F656C
      kind == 119 and index == 5 -> 0x696C5F6F
      kind == 119 and index == 6 -> 0x7473
      kind == 120 and index == 2 -> 0x6D756E65
      kind == 120 and index == 3 -> 0x62617265
      kind == 120 and index == 4 -> 0x695F656C
      kind == 120 and index == 5 -> 0x5F6F746E
      kind == 120 and index == 6 -> 0x70616D
      kind == 121 and index == 2 -> 0x6D756E65
      kind == 121 and index == 3 -> 0x62617265
      kind == 121 and index == 4 -> 0x695F656C
      kind == 121 and index == 5 -> 0x7265746E
      kind == 121 and index == 6 -> 0x72657073
      kind == 121 and index == 7 -> 0x6573
      kind == 122 and index == 2 -> 0x6D756E65
      kind == 122 and index == 3 -> 0x62617265
      kind == 122 and index == 4 -> 0x745F656C
      kind == 122 and index == 5 -> 0x696C5F6F
      kind == 122 and index == 6 -> 0x725F7473
      kind == 122 and index == 7 -> 0x65676E61
      kind == 123 and index == 2 -> 0x6D756E65
      kind == 123 and index == 3 -> 0x62617265
      kind == 123 and index == 4 -> 0x725F656C
      kind == 123 and index == 5 -> 0x63756465
      kind == 123 and index == 6 -> 0x65
      kind == 124 and index == 2 -> 0x6D756E65
      kind == 124 and index == 3 -> 0x62617265
      kind == 124 and index == 4 -> 0x725F656C
      kind == 124 and index == 5 -> 0x63756465
      kind == 124 and index == 6 -> 0x635F65
      kind == 125 and index == 2 -> 0x6D756E65
      kind == 125 and index == 3 -> 0x62617265
      kind == 125 and index == 4 -> 0x725F656C
      kind == 125 and index == 5 -> 0x63756465
      kind == 125 and index == 6 -> 0x61725F65
      kind == 125 and index == 7 -> 0x65676E
      kind == 126 and index == 2 -> 0x6D756E65
      kind == 126 and index == 3 -> 0x62617265
      kind == 126 and index == 4 -> 0x725F656C
      kind == 126 and index == 5 -> 0x63756465
      kind == 126 and index == 6 -> 0x75665F65
      kind == 126 and index == 7 -> 0x6E
      kind == 127 and index == 2 -> 0x6D756E65
      kind == 127 and index == 3 -> 0x62617265
      kind == 127 and index == 4 -> 0x6D5F656C
      kind == 127 and index == 5 -> 0x665F7061
      kind == 127 and index == 6 -> 0x6E75
      kind == 128 and index == 2 -> 0x6D756E65
      kind == 128 and index == 3 -> 0x62617265
      kind == 128 and index == 4 -> 0x6D5F656C
      kind == 128 and index == 5 -> 0x745F7061
      kind == 128 and index == 6 -> 0x5F6D7265
      kind == 128 and index == 7 -> 0x6E7566
      kind == 129 and index == 2 -> 0x6D756E65
      kind == 129 and index == 3 -> 0x62617265
      kind == 129 and index == 4 -> 0x6D5F656C
      kind == 129 and index == 5 -> 0x745F7061
      kind == 129 and index == 6 -> 0x5F6D7265
      kind == 129 and index == 7 -> 0x5F6E7566
      kind == 129 and index == 8 -> 0x63
      kind == 130 and index == 2 -> 0x6D756E65
      kind == 130 and index == 3 -> 0x62617265
      kind == 130 and index == 4 -> 0x665F656C
      kind == 130 and index == 5 -> 0x5F74616C
      kind == 130 and index == 6 -> 0x5F70616D
      kind == 130 and index == 7 -> 0x6D726574
      kind == 130 and index == 8 -> 0x6E75665F
      kind == 131 and index == 2 -> 0x65727473
      kind == 131 and index == 3 -> 0x665F6D61
      kind == 131 and index == 4 -> 0x65746C69
      kind == 131 and index == 5 -> 0x72
      kind == 132 and index == 2 -> 0x65727473
      kind == 132 and index == 3 -> 0x745F6D61
      kind == 132 and index == 4 -> 0x656B61
      kind == 133 and index == 2 -> 0x65727473
      kind == 133 and index == 3 -> 0x645F6D61
      kind == 133 and index == 4 -> 0x706F72
      kind == 134 and index == 2 -> 0x5F6E7566
      kind == 134 and index == 3 -> 0x74697261
      kind == 134 and index == 4 -> 0x79
      kind == 135 and index == 2 -> 0x5F6E7566
      kind == 135 and index == 3 -> 0x75736572
      kind == 135 and index == 4 -> 0x6D5F746C
      kind == 135 and index == 5 -> 0x65646F
      kind >= 136 and kind <= 140 and index == 0 -> 0x742E7865
      kind >= 136 and kind <= 140 and index == 1 -> 0x2E6D7265
      kind == 136 and index == 2 -> 0x636F7270
      kind == 136 and index == 3 -> 0x5F737365
      kind == 136 and index == 4 -> 0x74696177
      kind == 137 and index == 2 -> 0x6B726F77
      kind == 137 and index == 3 -> 0x725F7265
      kind == 137 and index == 4 -> 0x6E75
      kind == 138 and index == 2 -> 0x63746163
      kind == 138 and index == 3 -> 0x61765F68
      kind == 138 and index == 4 -> 0x65756C
      kind == 139 and index == 2 -> 0x6F726874
      kind == 139 and index == 3 -> 0x77
      kind == 140 and index == 2 -> 0x73696172
      kind == 140 and index == 3 -> 0x65
      kind == 141 and index == 0 -> 0x74697261
      kind == 141 and index == 1 -> 0x68732E68
      kind == 141 and index == 2 -> 0x696C
      kind >= 142 and kind <= 148 and index == 0 -> 0x742E7865
      kind >= 142 and kind <= 148 and index == 1 -> 0x2E6D7265
      kind == 142 and index == 2 -> 0x695F7369
      kind == 142 and index == 3 -> 0x6765746E
      kind == 142 and index == 4 -> 0x7265
      kind == 143 and index == 2 -> 0x665F7369
      kind == 143 and index == 3 -> 0x74616F6C
      kind == 144 and index == 2 -> 0x615F7369
      kind == 144 and index == 3 -> 0x6D6F74
      kind == 145 and index == 2 -> 0x625F7369
      kind == 145 and index == 3 -> 0x72616E69
      kind == 145 and index == 4 -> 0x79
      kind == 146 and index == 2 -> 0x6C5F7369
      kind == 146 and index == 3 -> 0x747369
      kind == 147 and index == 2 -> 0x745F7369
      kind == 147 and index == 3 -> 0x656C7075
      kind == 148 and index == 2 -> 0x6D5F7369
      kind == 148 and index == 3 -> 0x7061
      kind >= 150 and kind <= 151 and index == 0 -> 0x742E7865
      kind >= 150 and kind <= 151 and index == 1 -> 0x2E6D7265
      kind == 150 and index == 2 -> 0x6C707574
      kind == 150 and index == 3 -> 0x72665F65
      kind == 150 and index == 4 -> 0x6C5F6D6F
      kind == 150 and index == 5 -> 0x747369
      kind == 151 and index == 2 -> 0x5F70616D
      kind == 151 and index == 3 -> 0x6D6F7266
      kind == 151 and index == 4 -> 0x73696C5F
      kind == 151 and index == 5 -> 0x74
      kind >= 152 and kind <= 156 and index == 0 -> 0x742E7865
      kind >= 152 and kind <= 156 and index == 1 -> 0x2E6D7265
      kind >= 152 and kind <= 154 and index == 2 -> 0x656B616D
      kind >= 152 and kind <= 154 and index == 3 -> 0x6E75665F
      kind >= 153 and kind <= 154 and index == 4 -> 0x7469775F
      kind == 153 and index == 5 -> 0x72615F68
      kind == 153 and index == 6 -> 0x797469
      kind == 154 and index == 5 -> 0x69735F68
      kind == 154 and index == 6 -> 0x74616E67
      kind == 154 and index == 7 -> 0x657275
      kind >= 155 and kind <= 156 and index == 2 -> 0x5F6E7566
      kind == 155 and index == 3 -> 0x786469
      kind == 156 and index == 3 -> 0x766E65
      kind == 157 and index == 0 -> 0x6E665F5F
      kind == 157 and index == 1 -> 0x7369645F
      kind == 157 and index == 2 -> 0x63746170
      kind == 157 and index == 3 -> 0x68
      kind == 158 and index == 0 -> 0x636E7566
      kind == 158 and index == 1 -> 0x6E6F632E
      kind == 158 and index == 2 -> 0x6E617473
      kind == 158 and index == 3 -> 0x74
      kind == 159 and index == 0 -> 0x6D766C6C
      kind == 159 and index == 1 -> 0x6C6C612E
      kind == 159 and index == 2 -> 0x61636F
      kind == 160 and index == 0 -> 0x6D766C6C
      kind == 160 and index == 1 -> 0x746E692E
      kind == 160 and index == 2 -> 0x74706F74
      kind == 160 and index == 3 -> 0x72
      kind == 161 and index == 0 -> 0x6D766C6C
      kind == 161 and index == 1 -> 0x6C61632E
      kind == 161 and index == 2 -> 0x6C
      kind >= 162 and kind <= 165 and index == 0 -> 0x742E7865
      kind >= 162 and kind <= 165 and index == 1 -> 0x2E6D7265
      kind == 162 and index == 2 -> 0x5F706D6A
      kind == 162 and index == 3 -> 0x5F667562
      kind == 162 and index == 4 -> 0x657A6973
      kind == 163 and index == 2 -> 0x5F797274
      kind == 163 and index == 3 -> 0x68737570
      kind == 164 and index == 2 -> 0x6A746573
      kind == 164 and index == 3 -> 0x615F706D
      kind == 164 and index == 4 -> 0x726464
      kind == 165 and index == 2 -> 0x5F797274
      kind == 165 and index == 3 -> 0x706F70
      kind == 201 and index == 0 -> 0x756C6176
      kind == 201 and index == 1 -> 0x65
      kind == 202 and index == 0 -> 0x64657270
      kind == 202 and index == 1 -> 0x74616369
      kind == 202 and index == 2 -> 0x65
      kind == 203 and index == 0 -> 0x6C6C6163
      kind == 203 and index == 1 -> 0x6565
      kind == 204 and index == 0 -> 0x74697261
      kind == 204 and index == 1 -> 0x79
      kind == 205 and index == 0 -> 0x5F6D7973
      kind == 205 and index == 1 -> 0x656D616E
      kind == 206 and index == 0 -> 0x695F6E66
      kind == 206 and index == 1 -> 0x7864
      kind == 207 and index == 0 -> 0x5F766E65
      kind == 207 and index == 1 -> 0x6E656C
      kind == 208 and index == 0 -> 0x75736572
      kind == 208 and index == 1 -> 0x6D5F746C
      kind == 208 and index == 2 -> 0x65646F
      kind == 209 and index == 0 -> 0x5F677261
      kind == 209 and index == 1 -> 0x6E756F63
      kind == 209 and index == 2 -> 0x74
      kind == 210 and index == 0 -> 0x636E7566
      kind == 210 and index == 1 -> 0x6E6F6974
      kind == 210 and index == 2 -> 0x7079745F
      kind == 210 and index == 3 -> 0x65
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
      kind == 81 -> 2
      kind == 82 -> 1
      kind == 83 -> 1
      kind == 84 -> 1
      kind == 85 -> 2
      kind == 86 -> 1
      kind == 87 -> 2
      kind == 88 -> 1
      kind == 89 -> 2
      kind == 90 -> 3
      kind == 91 -> 1
      kind == 92 -> 1
      kind == 93 -> 2
      kind == 94 -> 2
      kind == 96 -> 1
      kind == 97 -> 1
      kind == 98 -> 1
      kind == 99 -> 1
      kind == 100 -> 1
      kind == 101 -> 1
      kind == 102 -> 1
      kind == 103 -> 2
      kind == 104 -> 2
      kind == 105 -> 2
      kind == 106 -> 2
      kind == 107 -> 1
      kind == 108 -> 1
      kind == 109 -> 1
      kind == 110 -> 1
      kind == 111 -> 1
      kind == 112 -> 1
      kind == 113 -> 2
      kind == 114 -> 1
      kind == 115 -> 1
      kind == 116 -> 1
      kind == 117 -> 1
      kind == 118 -> 1
      kind == 119 -> 1
      kind == 120 -> 2
      kind == 121 -> 2
      kind == 122 -> 2
      kind == 123 -> 3
      kind == 124 -> 4
      kind == 125 -> 4
      kind == 126 -> 3
      kind == 127 -> 2
      kind == 128 -> 2
      kind == 129 -> 6
      kind == 130 -> 2
      kind == 131 -> 2
      kind == 132 -> 2
      kind == 133 -> 2
      kind == 134 -> 1
      kind == 135 -> 1
      kind == 136 -> 1
      kind == 137 -> 2
      kind == 138 -> 0
      kind == 139 -> 1
      kind == 140 -> 2
      kind >= 142 and kind <= 148 -> 1
      kind >= 150 and kind <= 151 -> 1
      kind == 152 -> 6
      kind == 153 -> 7
      kind == 154 -> 8
      kind == 155 -> 1
      kind == 156 -> 2
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

  def term_type_accept(length, reversed_tail) do
    tail5 = Bitwise.band(reversed_tail, 0xFFFFFFFFFF)
    tail6 = Bitwise.band(reversed_tail, 0xFFFFFFFFFFFF)

    cond do
      length == 4 and reversed_tail == 0x7465726D -> 1
      length == 5 and reversed_tail == 0x626F756E64 -> 1
      length == 7 and reversed_tail == 0x756E626F756E64 -> 1
      length >= 5 and tail5 == 0x2E7465726D -> 1
      length >= 6 and tail6 == 0x2E626F756E64 -> 1
      length >= 8 and reversed_tail == 0x2E756E626F756E64 -> 1
      true -> 0
    end
  end

  def aggregate_accept(kind, arity) do
    cond do
      kind == 149 and arity >= 0 -> 1
      kind == 150 and arity >= 0 -> 1
      kind == 151 and arity >= 0 and Bitwise.band(arity, 1) == 0 -> 1
      true -> 0
    end
  end

  # Rewrite orchestration runs in Batata-compiled code. CompilerABI.Host is an
  # explicit allowlisted scalar ABI whose values are borrowed opaque handles.
  def rewrite(pattern) do
    action = pattern_action(pattern)
    target = pattern_target(pattern)

    cond do
      action == 1 -> rewrite_aggregate(target)
      action == 2 -> rewrite_apply()
      action == 3 -> rewrite_binary(target)
      action == 4 -> rewrite_binary_term()
      action == 5 -> rewrite_box()
      action == 6 -> rewrite_call(target)
      action == 7 -> rewrite_cmp()
      action == 8 -> rewrite_func_addr(target)
      action == 9 -> rewrite_func(target)
      action == 10 -> rewrite_function_value(target)
      action == 11 -> rewrite_identity()
      action == 12 -> rewrite_if(target)
      action == 13 -> rewrite_literal(target)
      action == 14 -> rewrite_predicate(target)
      action == 15 -> rewrite_return(target)
      action == 16 -> rewrite_runtime_call(target)
      action == 19 -> rewrite_yield(target)
      true -> 0
    end
  end

  defp rewrite_func(target) do
    regions = CompilerABI.Host.operation_region_count()

    if valid_shape(0, 0) == 1 and regions == 1 do
      block = CompilerABI.Host.single_region_block(0)
      arguments = CompilerABI.Host.block_argument_count(block)
      terminator = CompilerABI.Host.block_terminator(block)
      returns = CompilerABI.Host.operation_operand_count(terminator)
      terminator_results = CompilerABI.Host.operation_result_count(terminator)

      counts_accepted =
        Bitwise.band(
          Bitwise.band(arguments >= 0, arguments <= structural_limit(1)),
          Bitwise.band(
            Bitwise.band(returns >= 0, returns <= structural_limit(1)),
            terminator_results == 0
          )
        )

      if counts_accepted == 1 and CompilerABI.Host.function_type_reset() == 1 and
           stage_block_argument_types(block, 0, arguments) == 1 and
           stage_operation_operand_types(terminator, 0, returns) == 1 do
        function_type = CompilerABI.Host.function_type_create()
        function_type_attribute = CompilerABI.Host.type_attribute(function_type)
        symbol = CompilerABI.Host.operation_attribute(205)
        symbol_length = CompilerABI.Host.attribute_string_length(symbol)
        location = CompilerABI.Host.operation_location()

        if symbol_length > 0 and CompilerABI.Host.builder_reset(target, location) == 1 and
             CompilerABI.Host.builder_add_attribute(205, symbol) == 1 and
             CompilerABI.Host.builder_add_attribute(210, function_type_attribute) == 1 do
          CompilerABI.Host.builder_create_with_regions(1)
          |> CompilerABI.Host.replace_regions(1)
        else
          0
        end
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_if(target) do
    results = CompilerABI.Host.source_result_count()

    counts_accepted =
      Bitwise.band(results >= 0, results <= structural_limit(1))

    if counts_accepted == 1 and valid_shape(1, results) == 1 do
      location = CompilerABI.Host.operation_location()
      i1 = CompilerABI.Host.integer_type(1)

      condition =
        if CompilerABI.Host.builder_reset(15, location) == 1 and
             CompilerABI.Host.builder_add_operand(CompilerABI.Host.converted_operand(0)) == 1 and
             CompilerABI.Host.builder_add_result_type(i1) == 1 do
          CompilerABI.Host.builder_create()
          |> CompilerABI.Host.operation_result(0)
        else
          0
        end

      if condition != 0 and CompilerABI.Host.builder_reset(target, location) == 1 and
           CompilerABI.Host.builder_add_operand(condition) == 1 and
           stage_converted_result_types(0, results) == 1 do
        CompilerABI.Host.builder_create_with_regions(2)
        |> CompilerABI.Host.replace_regions(2)
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_binary(target) do
    if valid_shape(2, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           stage_converted_operands(0, 2) == 1 and
           CompilerABI.Host.builder_add_result_type(result_type) == 1 do
        replace_created_result(CompilerABI.Host.builder_create())
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_identity() do
    if valid_shape(1, 1) == 1 do
      CompilerABI.Host.replace_one(CompilerABI.Host.converted_operand(0))
    else
      0
    end
  end

  defp rewrite_literal(target) do
    if valid_shape(0, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      value = CompilerABI.Host.operation_attribute(201)

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           CompilerABI.Host.builder_add_result_type(result_type) == 1 and
           CompilerABI.Host.builder_add_attribute(201, value) == 1 do
        replace_created_result(CompilerABI.Host.builder_create())
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_runtime_call(target) do
    arity = runtime_arity(target)

    if arity >= 0 and valid_shape(arity, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(10, location) == 1 and
           stage_converted_operands(0, arity) == 1 do
        target
        |> CompilerABI.Host.builder_create_call(result_type)
        |> replace_created_result()
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_yield(target) do
    count = CompilerABI.Host.converted_operand_count()

    if valid_shape(count, 0) == 1 do
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           stage_converted_operands(0, count) == 1 and
           CompilerABI.Host.builder_create() != 0 do
        CompilerABI.Host.replace_none()
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_box() do
    if valid_shape(1, 1) == 1 do
      source_word(CompilerABI.Host.converted_operand(0))
      |> CompilerABI.Host.replace_one()
    else
      0
    end
  end

  defp rewrite_predicate(target) do
    if valid_shape(1, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      word = source_word(CompilerABI.Host.converted_operand(0))

      call_one(target, word, result_type, location)
      |> replace_created_result()
    else
      0
    end
  end

  defp rewrite_cmp() do
    if valid_shape(2, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      predicate = CompilerABI.Host.operation_attribute(202)
      length = CompilerABI.Host.attribute_string_length(predicate)
      word = CompilerABI.Host.attribute_string_word(predicate, 0)
      code = cmp_predicate(length, word)

      if length > 0 and length <= 4 and code >= 0 do
        i1 = CompilerABI.Host.integer_type(1)
        code_attribute = CompilerABI.Host.integer_attribute(result_type, code)

        if CompilerABI.Host.builder_reset(7, location) == 1 and
             stage_converted_operands(0, 2) == 1 and
             CompilerABI.Host.builder_add_result_type(i1) == 1 and
             CompilerABI.Host.builder_add_attribute(202, code_attribute) == 1 do
          cmp_result =
            CompilerABI.Host.builder_create()
            |> CompilerABI.Host.operation_result(0)

          if CompilerABI.Host.builder_reset(8, location) == 1 and
               CompilerABI.Host.builder_add_operand(cmp_result) == 1 and
               CompilerABI.Host.builder_add_result_type(result_type) == 1 do
            replace_created_result(CompilerABI.Host.builder_create())
          else
            0
          end
        else
          0
        end
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_binary_term() do
    count = CompilerABI.Host.converted_operand_count()

    if valid_shape(count, 1) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      word_type = CompilerABI.Host.integer_type(64)
      tail = integer_constant(word_type, 1, location)
      list = build_term_list(count, tail, word_type, location)

      call_one(14, list, result_type, location)
      |> replace_created_result()
    else
      0
    end
  end

  defp rewrite_aggregate(target) do
    count = CompilerABI.Host.converted_operand_count()

    if aggregate_accept(target, count) == 1 and valid_shape(count, 1) == 1 and
         converted_operands_are_i64(0, count) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      tail = integer_constant(result_type, 1, location)
      list = build_term_list(count, tail, result_type, location)

      result =
        if target == 149 do
          list
        else
          target
          |> call_one(list, result_type, location)
          |> CompilerABI.Host.operation_result(0)
        end

      CompilerABI.Host.replace_one(result)
    else
      0
    end
  end

  defp rewrite_function_value(target) do
    count = CompilerABI.Host.converted_operand_count()
    fn_idx = integer_operation_attribute(206)
    env_len = integer_operation_attribute(207)
    arity = if target >= 153, do: integer_operation_attribute(204), else: -1
    result_mode = if target == 154, do: integer_operation_attribute(208), else: -1

    if function_value_accept(target, count, arity, result_mode, env_len) == 1 and
         valid_shape(env_len, 1) == 1 and converted_operands_are_i64(0, count) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      fn_idx_value = integer_constant(result_type, fn_idx, location)

      arity_value =
        if target >= 153, do: integer_constant(result_type, arity, location), else: 0

      result_mode_value =
        if target == 154, do: integer_constant(result_type, result_mode, location), else: 0

      env_len_value = integer_constant(result_type, env_len, location)
      zero = integer_constant(result_type, 0, location)

      if CompilerABI.Host.type_is_i64(result_type) == 1 and
           CompilerABI.Host.builder_reset(10, location) == 1 and
           stage_function_metadata(
             target,
             fn_idx_value,
             arity_value,
             result_mode_value,
             env_len_value
           ) ==
             1 and
           stage_converted_operands(0, count) == 1 and
           stage_zero_padding(env_len, zero) == 1 do
        target
        |> CompilerABI.Host.builder_create_call(result_type)
        |> replace_created_result()
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_apply() do
    count = CompilerABI.Host.converted_operand_count()
    arg_count = integer_operation_attribute(209)

    if function_value_accept(157, count, arg_count, -1, -1) == 1 and
         valid_shape(arg_count + 1, 1) == 1 and converted_operands_are_i64(0, count) == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()
      closure = CompilerABI.Host.converted_operand(0)
      fn_idx = call_result(call_one(155, closure, result_type, location))
      env0 = closure_env(closure, 0, result_type, location)
      env1 = closure_env(closure, 1, result_type, location)
      env2 = closure_env(closure, 2, result_type, location)
      env3 = closure_env(closure, 3, result_type, location)
      zero = integer_constant(result_type, 0, location)

      if CompilerABI.Host.type_is_i64(result_type) == 1 and
           CompilerABI.Host.builder_reset(10, location) == 1 and
           CompilerABI.Host.builder_add_operand(fn_idx) == 1 and
           CompilerABI.Host.builder_add_operand(env0) == 1 and
           CompilerABI.Host.builder_add_operand(env1) == 1 and
           CompilerABI.Host.builder_add_operand(env2) == 1 and
           CompilerABI.Host.builder_add_operand(env3) == 1 and
           stage_converted_operands(1, count) == 1 and
           stage_zero_padding(arg_count, zero) == 1 and
           CompilerABI.Host.builder_add_result_type(result_type) == 1 and
           CompilerABI.Host.builder_add_flat_symbol(203, 157) == 1 do
        replace_created_result(CompilerABI.Host.builder_create())
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_func_addr(target) do
    if valid_shape(0, 1) == 1 do
      symbol = CompilerABI.Host.operation_attribute(205)
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           CompilerABI.Host.builder_add_result_type(result_type) == 1 and
           CompilerABI.Host.builder_add_flat_symbol_from_attribute(201, symbol) == 1 do
        replace_created_result(CompilerABI.Host.builder_create())
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_call(target) do
    count = CompilerABI.Host.converted_operand_count()
    arity = integer_operation_attribute(204)
    callee = CompilerABI.Host.operation_attribute(203)

    shape_accepted =
      Bitwise.band(
        Bitwise.band(count >= 0, count <= structural_limit(1)),
        Bitwise.band(arity == count, valid_shape(count, 1) == 1)
      )

    if shape_accepted == 1 do
      result_type = converted_result_type(0)
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           stage_converted_operands(0, count) == 1 and
           CompilerABI.Host.builder_add_result_type(result_type) == 1 and
           CompilerABI.Host.builder_add_flat_symbol_from_attribute(203, callee) == 1 do
        replace_created_result(CompilerABI.Host.builder_create())
      else
        0
      end
    else
      0
    end
  end

  defp rewrite_return(target) do
    count = CompilerABI.Host.converted_operand_count()

    if count >= 0 and count <= 1 and valid_shape(count, 0) == 1 do
      location = CompilerABI.Host.operation_location()

      if CompilerABI.Host.builder_reset(target, location) == 1 and
           stage_converted_operands(0, count) == 1 and
           CompilerABI.Host.builder_create() != 0 do
        CompilerABI.Host.replace_none()
      else
        0
      end
    else
      0
    end
  end

  defp integer_operation_attribute(name_id) do
    name_id
    |> CompilerABI.Host.operation_attribute()
    |> CompilerABI.Host.attribute_integer_value()
  end

  defp stage_function_metadata(
         target,
         fn_idx_value,
         arity_value,
         result_mode_value,
         env_len_value
       ) do
    if CompilerABI.Host.builder_add_operand(fn_idx_value) == 1 do
      cond do
        target == 152 ->
          CompilerABI.Host.builder_add_operand(env_len_value)

        target == 153 ->
          Bitwise.band(
            CompilerABI.Host.builder_add_operand(arity_value),
            CompilerABI.Host.builder_add_operand(env_len_value)
          )

        target == 154 ->
          Bitwise.band(
            CompilerABI.Host.builder_add_operand(arity_value),
            Bitwise.band(
              CompilerABI.Host.builder_add_operand(result_mode_value),
              CompilerABI.Host.builder_add_operand(env_len_value)
            )
          )

        true ->
          0
      end
    else
      0
    end
  end

  defp stage_zero_padding(index, zero) do
    if index == 4 do
      1
    else
      if index >= 0 and index < 4 and CompilerABI.Host.builder_add_operand(zero) == 1 do
        stage_zero_padding(index + 1, zero)
      else
        0
      end
    end
  end

  defp closure_env(closure, index, result_type, location) do
    index_value = integer_constant(result_type, index, location)
    call_two(156, closure, index_value, result_type, location) |> call_result()
  end

  defp call_result(operation), do: CompilerABI.Host.operation_result(operation, 0)

  defp valid_shape(expected_operands, expected_results) do
    source_operands = CompilerABI.Host.source_operand_count()
    source_results = CompilerABI.Host.source_result_count()
    converted_operands = CompilerABI.Host.converted_operand_count()

    Bitwise.band(
      CompilerABI.Host.healthy(),
      Bitwise.band(
        source_operands == converted_operands,
        pattern_accept(
          source_operands,
          source_results,
          expected_operands,
          expected_results
        )
      )
    )
  end

  defp converted_result_type(index) do
    index
    |> CompilerABI.Host.source_result()
    |> CompilerABI.Host.value_type()
    |> CompilerABI.Host.convert_type()
  end

  defp stage_converted_operands(index, count) do
    if index == count do
      1
    else
      if index < count and
           index
           |> CompilerABI.Host.converted_operand()
           |> CompilerABI.Host.builder_add_operand() == 1 do
        stage_converted_operands(index + 1, count)
      else
        0
      end
    end
  end

  defp stage_converted_result_types(index, count) do
    if index == count do
      1
    else
      converted_type =
        index
        |> CompilerABI.Host.source_result()
        |> CompilerABI.Host.value_type()
        |> CompilerABI.Host.convert_type()

      if index < count and CompilerABI.Host.builder_add_result_type(converted_type) == 1 do
        stage_converted_result_types(index + 1, count)
      else
        0
      end
    end
  end

  defp stage_block_argument_types(block, index, count) do
    if index == count do
      1
    else
      converted_type =
        block
        |> CompilerABI.Host.block_argument(index)
        |> CompilerABI.Host.value_type()
        |> CompilerABI.Host.convert_type()

      if index < count and CompilerABI.Host.function_type_add_input(converted_type) == 1 do
        stage_block_argument_types(block, index + 1, count)
      else
        0
      end
    end
  end

  defp stage_operation_operand_types(operation, index, count) do
    if index == count do
      1
    else
      converted_type =
        operation
        |> CompilerABI.Host.operation_operand(index)
        |> CompilerABI.Host.value_type()
        |> CompilerABI.Host.convert_type()

      if index < count and CompilerABI.Host.function_type_add_result(converted_type) == 1 do
        stage_operation_operand_types(operation, index + 1, count)
      else
        0
      end
    end
  end

  defp converted_operands_are_i64(index, count) do
    if index == count do
      1
    else
      is_i64 =
        index
        |> CompilerABI.Host.converted_operand()
        |> CompilerABI.Host.value_type()
        |> CompilerABI.Host.type_is_i64()

      if index < count and is_i64 == 1 do
        converted_operands_are_i64(index + 1, count)
      else
        0
      end
    end
  end

  defp source_word(converted) do
    original_type =
      0
      |> CompilerABI.Host.source_operand()
      |> CompilerABI.Host.value_type()

    converted_type = CompilerABI.Host.value_type(converted)

    if CompilerABI.Host.type_is_i64(converted_type) == 1 do
      if CompilerABI.Host.type_is_i64(original_type) == 1 do
        location = CompilerABI.Host.operation_location()
        shift = integer_constant(converted_type, 3, location)
        create_binary(141, converted, shift, converted_type, location)
      else
        length = CompilerABI.Host.dynamic_type_length(original_type)
        tail = CompilerABI.Host.dynamic_type_tail(original_type)

        if term_type_accept(length, tail) == 1, do: converted, else: 0
      end
    else
      0
    end
  end

  defp integer_constant(type, value, location) do
    attribute = CompilerABI.Host.integer_attribute(type, value)

    if CompilerABI.Host.builder_reset(1, location) == 1 and
         CompilerABI.Host.builder_add_result_type(type) == 1 and
         CompilerABI.Host.builder_add_attribute(201, attribute) == 1 do
      CompilerABI.Host.builder_create()
      |> CompilerABI.Host.operation_result(0)
    else
      0
    end
  end

  defp create_binary(target, left, right, result_type, location) do
    if CompilerABI.Host.builder_reset(target, location) == 1 and
         CompilerABI.Host.builder_add_operand(left) == 1 and
         CompilerABI.Host.builder_add_operand(right) == 1 and
         CompilerABI.Host.builder_add_result_type(result_type) == 1 do
      CompilerABI.Host.builder_create()
      |> CompilerABI.Host.operation_result(0)
    else
      0
    end
  end

  defp call_one(target, operand, result_type, location) do
    if CompilerABI.Host.builder_reset(10, location) == 1 and
         CompilerABI.Host.builder_add_operand(operand) == 1 do
      CompilerABI.Host.builder_create_call(target, result_type)
    else
      0
    end
  end

  defp call_two(target, first, second, result_type, location) do
    if CompilerABI.Host.builder_reset(10, location) == 1 and
         CompilerABI.Host.builder_add_operand(first) == 1 and
         CompilerABI.Host.builder_add_operand(second) == 1 do
      CompilerABI.Host.builder_create_call(target, result_type)
    else
      0
    end
  end

  defp build_term_list(index, tail, word_type, location) do
    if index == 0 do
      tail
    else
      head = CompilerABI.Host.converted_operand(index - 1)

      next =
        13
        |> call_two(head, tail, word_type, location)
        |> CompilerABI.Host.operation_result(0)

      build_term_list(index - 1, next, word_type, location)
    end
  end

  defp replace_created_result(operation) do
    operation
    |> CompilerABI.Host.operation_result(0)
    |> CompilerABI.Host.replace_one()
  end

  def function_value_accept(kind, operands, arity, result_mode, env_len) do
    env_matches =
      Bitwise.band(
        Bitwise.band(env_len >= 0, env_len <= 4),
        operands == env_len
      )

    cond do
      kind == 152 ->
        env_matches

      kind == 153 ->
        Bitwise.band(env_matches, Bitwise.band(arity >= 0, arity <= 4))

      kind == 154 ->
        Bitwise.band(
          env_matches,
          Bitwise.band(
            Bitwise.band(arity >= 0, arity <= 4),
            Bitwise.band(result_mode >= 0, result_mode <= 1)
          )
        )

      kind == 157 ->
        Bitwise.band(
          Bitwise.band(arity >= 0, arity <= 4),
          operands == arity + 1
        )

      true ->
        0
    end
  end

  # The compiled Batata source is the only pattern registry. The native
  # trampoline decodes these scalar words without embedding dialect roots.
  def pattern_count(), do: 158

  def pattern_namespace_length(), do: 7

  def pattern_namespace_word(index) do
    cond do
      index == 0 -> 0x61746162
      index == 1 -> 0x2E6174
      true -> -1
    end
  end

  def pattern_root_length(pattern) do
    cond do
      pattern == 0 -> 6
      pattern == 1 -> 8
      pattern == 2 -> 9
      pattern == 3 -> 18
      pattern == 4 -> 18
      pattern == 5 -> 19
      pattern == 6 -> 13
      pattern == 7 -> 16
      pattern == 8 -> 14
      pattern == 9 -> 15
      pattern == 10 -> 15
      pattern == 11 -> 18
      pattern == 12 -> 21
      pattern == 13 -> 20
      pattern == 14 -> 6
      pattern == 15 -> 7
      pattern == 16 -> 14
      pattern == 17 -> 13
      pattern == 18 -> 6
      pattern == 19 -> 14
      pattern == 20 -> 13
      pattern == 21 -> 16
      pattern == 22 -> 16
      pattern == 23 -> 19
      pattern == 24 -> 15
      pattern == 25 -> 12
      pattern == 26 -> 16
      pattern == 27 -> 12
      pattern == 28 -> 6
      pattern == 29 -> 19
      pattern == 30 -> 31
      pattern == 31 -> 25
      pattern == 32 -> 22
      pattern == 33 -> 21
      pattern == 34 -> 26
      pattern == 35 -> 28
      pattern == 36 -> 20
      pattern == 37 -> 22
      pattern == 38 -> 24
      pattern == 39 -> 26
      pattern == 40 -> 21
      pattern == 41 -> 27
      pattern == 42 -> 7
      pattern == 43 -> 17
      pattern == 44 -> 19
      pattern == 45 -> 15
      pattern == 46 -> 18
      pattern == 47 -> 12
      pattern == 48 -> 18
      pattern == 49 -> 12
      pattern == 50 -> 24
      pattern == 51 -> 12
      pattern == 52 -> 18
      pattern == 53 -> 7
      pattern == 54 -> 12
      pattern == 55 -> 5
      pattern == 56 -> 13
      pattern == 57 -> 16
      pattern == 58 -> 21
      pattern == 59 -> 19
      pattern == 60 -> 10
      pattern == 61 -> 12
      pattern == 62 -> 11
      pattern == 63 -> 13
      pattern == 64 -> 10
      pattern == 65 -> 9
      pattern == 66 -> 11
      pattern == 67 -> 7
      pattern == 68 -> 7
      pattern == 69 -> 12
      pattern == 70 -> 15
      pattern == 71 -> 11
      pattern == 72 -> 12
      pattern == 73 -> 14
      pattern == 74 -> 12
      pattern == 75 -> 6
      pattern == 76 -> 16
      pattern == 77 -> 14
      pattern == 78 -> 15
      pattern == 79 -> 17
      pattern == 80 -> 11
      pattern == 81 -> 22
      pattern == 82 -> 26
      pattern == 83 -> 6
      pattern == 84 -> 12
      pattern == 85 -> 13
      pattern == 86 -> 10
      pattern == 87 -> 19
      pattern == 88 -> 16
      pattern == 89 -> 13
      pattern == 90 -> 10
      pattern == 91 -> 17
      pattern == 92 -> 6
      pattern == 93 -> 14
      pattern == 94 -> 11
      pattern == 95 -> 15
      pattern == 96 -> 15
      pattern == 97 -> 22
      pattern == 98 -> 17
      pattern == 99 -> 22
      pattern == 100 -> 20
      pattern == 101 -> 15
      pattern == 102 -> 21
      pattern == 103 -> 8
      pattern == 104 -> 10
      pattern == 105 -> 20
      pattern == 106 -> 16
      pattern == 107 -> 20
      pattern == 108 -> 17
      pattern == 109 -> 6
      pattern == 110 -> 19
      pattern == 111 -> 16
      pattern == 112 -> 17
      pattern == 113 -> 24
      pattern == 114 -> 26
      pattern == 115 -> 19
      pattern == 116 -> 19
      pattern == 117 -> 18
      pattern == 118 -> 19
      pattern == 119 -> 21
      pattern == 120 -> 9
      pattern == 121 -> 17
      pattern == 122 -> 18
      pattern == 123 -> 16
      pattern == 124 -> 16
      pattern == 125 -> 16
      pattern == 126 -> 7
      pattern == 127 -> 7
      pattern == 128 -> 8
      pattern == 129 -> 14
      pattern == 130 -> 16
      pattern == 131 -> 14
      pattern == 132 -> 19
      pattern == 133 -> 17
      pattern == 134 -> 26
      pattern == 135 -> 18
      pattern == 136 -> 16
      pattern == 137 -> 6
      pattern == 138 -> 10
      pattern == 139 -> 16
      pattern == 140 -> 14
      pattern == 141 -> 22
      pattern == 142 -> 21
      pattern == 143 -> 14
      pattern == 144 -> 8
      pattern == 145 -> 9
      pattern == 146 -> 10
      pattern == 147 -> 6
      pattern == 148 -> 8
      pattern == 149 -> 12
      pattern == 150 -> 15
      pattern == 151 -> 8
      pattern == 152 -> 17
      pattern == 153 -> 9
      pattern == 154 -> 6
      pattern == 155 -> 13
      pattern == 156 -> 8
      pattern == 157 -> 13
      true -> -1
    end
  end

  def pattern_root_word(pattern, index) do
    cond do
      pattern == 0 and index == 0 -> 0x612E7865
      pattern == 0 and index == 1 -> 0x6464
      pattern == 1 and index == 0 -> 0x612E7865
      pattern == 1 and index == 1 -> 0x796C7070
      pattern == 2 and index == 0 -> 0x622E7865
      pattern == 2 and index == 1 -> 0x72616E69
      pattern == 2 and index == 2 -> 0x79
      pattern == 3 and index == 0 -> 0x622E7865
      pattern == 3 and index == 1 -> 0x72616E69
      pattern == 3 and index == 2 -> 0x65645F79
      pattern == 3 and index == 3 -> 0x65646F63
      pattern == 3 and index == 4 -> 0x3631
      pattern == 4 and index == 0 -> 0x622E7865
      pattern == 4 and index == 1 -> 0x72616E69
      pattern == 4 and index == 2 -> 0x6E655F79
      pattern == 4 and index == 3 -> 0x65646F63
      pattern == 4 and index == 4 -> 0x3631
      pattern == 5 and index == 0 -> 0x622E7865
      pattern == 5 and index == 1 -> 0x72616E69
      pattern == 5 and index == 2 -> 0x72665F79
      pattern == 5 and index == 3 -> 0x6C5F6D6F
      pattern == 5 and index == 4 -> 0x747369
      pattern == 6 and index == 0 -> 0x622E7865
      pattern == 6 and index == 1 -> 0x72616E69
      pattern == 6 and index == 2 -> 0x65675F79
      pattern == 6 and index == 3 -> 0x74
      pattern == 7 and index == 0 -> 0x622E7865
      pattern == 7 and index == 1 -> 0x72616E69
      pattern == 7 and index == 2 -> 0x656C5F79
      pattern == 7 and index == 3 -> 0x6874676E
      pattern == 8 and index == 0 -> 0x622E7865
      pattern == 8 and index == 1 -> 0x72616E69
      pattern == 8 and index == 2 -> 0x61705F79
      pattern == 8 and index == 3 -> 0x7472
      pattern == 9 and index == 0 -> 0x622E7865
      pattern == 9 and index == 1 -> 0x72616E69
      pattern == 9 and index == 2 -> 0x75715F79
      pattern == 9 and index == 3 -> 0x65746F
      pattern == 10 and index == 0 -> 0x622E7865
      pattern == 10 and index == 1 -> 0x72616E69
      pattern == 10 and index == 2 -> 0x6C735F79
      pattern == 10 and index == 3 -> 0x656369
      pattern == 11 and index == 0 -> 0x622E7865
      pattern == 11 and index == 1 -> 0x72616E69
      pattern == 11 and index == 2 -> 0x74755F79
      pattern == 11 and index == 3 -> 0x675F3866
      pattern == 11 and index == 4 -> 0x7465
      pattern == 12 and index == 0 -> 0x622E7865
      pattern == 12 and index == 1 -> 0x72616E69
      pattern == 12 and index == 2 -> 0x74755F79
      pattern == 12 and index == 3 -> 0x6C5F3866
      pattern == 12 and index == 4 -> 0x74676E65
      pattern == 12 and index == 5 -> 0x68
      pattern == 13 and index == 0 -> 0x622E7865
      pattern == 13 and index == 1 -> 0x72616E69
      pattern == 13 and index == 2 -> 0x74755F79
      pattern == 13 and index == 3 -> 0x775F3866
      pattern == 13 and index == 4 -> 0x68746469
      pattern == 14 and index == 0 -> 0x622E7865
      pattern == 14 and index == 1 -> 0x786F
      pattern == 15 and index == 0 -> 0x632E7865
      pattern == 15 and index == 1 -> 0x6C6C61
      pattern == 16 and index == 0 -> 0x632E7865
      pattern == 16 and index == 1 -> 0x68637461
      pattern == 16 and index == 2 -> 0x6C61765F
      pattern == 16 and index == 3 -> 0x6575
      pattern == 17 and index == 0 -> 0x632E7865
      pattern == 17 and index == 1 -> 0x6B636F6C
      pattern == 17 and index == 2 -> 0x696E695F
      pattern == 17 and index == 3 -> 0x74
      pattern == 18 and index == 0 -> 0x632E7865
      pattern == 18 and index == 1 -> 0x706D
      pattern == 19 and index == 0 -> 0x632E7865
      pattern == 19 and index == 1 -> 0x5F746E6F
      pattern == 19 and index == 2 -> 0x69746361
      pattern == 19 and index == 3 -> 0x6576
      pattern == 20 and index == 0 -> 0x632E7865
      pattern == 20 and index == 1 -> 0x5F746E6F
      pattern == 20 and index == 2 -> 0x61656C63
      pattern == 20 and index == 3 -> 0x72
      pattern == 21 and index == 0 -> 0x632E7865
      pattern == 21 and index == 1 -> 0x5F746E6F
      pattern == 21 and index == 2 -> 0x64616F6C
      pattern == 21 and index == 3 -> 0x6363615F
      pattern == 22 and index == 0 -> 0x632E7865
      pattern == 22 and index == 1 -> 0x5F746E6F
      pattern == 22 and index == 2 -> 0x64616F6C
      pattern == 22 and index == 3 -> 0x6772615F
      pattern == 23 and index == 0 -> 0x632E7865
      pattern == 23 and index == 1 -> 0x5F746E6F
      pattern == 23 and index == 2 -> 0x64616F6C
      pattern == 23 and index == 3 -> 0x7275635F
      pattern == 23 and index == 4 -> 0x726F73
      pattern == 24 and index == 0 -> 0x632E7865
      pattern == 24 and index == 1 -> 0x5F746E6F
      pattern == 24 and index == 2 -> 0x646E6570
      pattern == 24 and index == 3 -> 0x676E69
      pattern == 25 and index == 0 -> 0x632E7865
      pattern == 25 and index == 1 -> 0x5F746E6F
      pattern == 25 and index == 2 -> 0x65766173
      pattern == 26 and index == 0 -> 0x632E7865
      pattern == 26 and index == 1 -> 0x65727275
      pattern == 26 and index == 2 -> 0x655F746E
      pattern == 26 and index == 3 -> 0x7972746E
      pattern == 27 and index == 0 -> 0x642E7865
      pattern == 27 and index == 1 -> 0x6E6F6D65
      pattern == 27 and index == 2 -> 0x726F7469
      pattern == 28 and index == 0 -> 0x642E7865
      pattern == 28 and index == 1 -> 0x7669
      pattern == 29 and index == 0 -> 0x652E7865
      pattern == 29 and index == 1 -> 0x656D756E
      pattern == 29 and index == 2 -> 0x6C626172
      pattern == 29 and index == 3 -> 0x6F635F65
      pattern == 29 and index == 4 -> 0x746E75
      pattern == 30 and index == 0 -> 0x652E7865
      pattern == 30 and index == 1 -> 0x656D756E
      pattern == 30 and index == 2 -> 0x6C626172
      pattern == 30 and index == 3 -> 0x6C665F65
      pattern == 30 and index == 4 -> 0x6D5F7461
      pattern == 30 and index == 5 -> 0x745F7061
      pattern == 30 and index == 6 -> 0x5F6D7265
      pattern == 30 and index == 7 -> 0x6E7566
      pattern == 31 and index == 0 -> 0x652E7865
      pattern == 31 and index == 1 -> 0x656D756E
      pattern == 31 and index == 2 -> 0x6C626172
      pattern == 31 and index == 3 -> 0x6E695F65
      pattern == 31 and index == 4 -> 0x73726574
      pattern == 31 and index == 5 -> 0x73726570
      pattern == 31 and index == 6 -> 0x65
      pattern == 32 and index == 0 -> 0x652E7865
      pattern == 32 and index == 1 -> 0x656D756E
      pattern == 32 and index == 2 -> 0x6C626172
      pattern == 32 and index == 3 -> 0x6E695F65
      pattern == 32 and index == 4 -> 0x6D5F6F74
      pattern == 32 and index == 5 -> 0x7061
      pattern == 33 and index == 0 -> 0x652E7865
      pattern == 33 and index == 1 -> 0x656D756E
      pattern == 33 and index == 2 -> 0x6C626172
      pattern == 33 and index == 3 -> 0x616D5F65
      pattern == 33 and index == 4 -> 0x75665F70
      pattern == 33 and index == 5 -> 0x6E
      pattern == 34 and index == 0 -> 0x652E7865
      pattern == 34 and index == 1 -> 0x656D756E
      pattern == 34 and index == 2 -> 0x6C626172
      pattern == 34 and index == 3 -> 0x616D5F65
      pattern == 34 and index == 4 -> 0x65745F70
      pattern == 34 and index == 5 -> 0x665F6D72
      pattern == 34 and index == 6 -> 0x6E75
      pattern == 35 and index == 0 -> 0x652E7865
      pattern == 35 and index == 1 -> 0x656D756E
      pattern == 35 and index == 2 -> 0x6C626172
      pattern == 35 and index == 3 -> 0x616D5F65
      pattern == 35 and index == 4 -> 0x65745F70
      pattern == 35 and index == 5 -> 0x665F6D72
      pattern == 35 and index == 6 -> 0x635F6E75
      pattern == 36 and index == 0 -> 0x652E7865
      pattern == 36 and index == 1 -> 0x656D756E
      pattern == 36 and index == 2 -> 0x6C626172
      pattern == 36 and index == 3 -> 0x65725F65
      pattern == 36 and index == 4 -> 0x65637564
      pattern == 37 and index == 0 -> 0x652E7865
      pattern == 37 and index == 1 -> 0x656D756E
      pattern == 37 and index == 2 -> 0x6C626172
      pattern == 37 and index == 3 -> 0x65725F65
      pattern == 37 and index == 4 -> 0x65637564
      pattern == 37 and index == 5 -> 0x635F
      pattern == 38 and index == 0 -> 0x652E7865
      pattern == 38 and index == 1 -> 0x656D756E
      pattern == 38 and index == 2 -> 0x6C626172
      pattern == 38 and index == 3 -> 0x65725F65
      pattern == 38 and index == 4 -> 0x65637564
      pattern == 38 and index == 5 -> 0x6E75665F
      pattern == 39 and index == 0 -> 0x652E7865
      pattern == 39 and index == 1 -> 0x656D756E
      pattern == 39 and index == 2 -> 0x6C626172
      pattern == 39 and index == 3 -> 0x65725F65
      pattern == 39 and index == 4 -> 0x65637564
      pattern == 39 and index == 5 -> 0x6E61725F
      pattern == 39 and index == 6 -> 0x6567
      pattern == 40 and index == 0 -> 0x652E7865
      pattern == 40 and index == 1 -> 0x656D756E
      pattern == 40 and index == 2 -> 0x6C626172
      pattern == 40 and index == 3 -> 0x6F745F65
      pattern == 40 and index == 4 -> 0x73696C5F
      pattern == 40 and index == 5 -> 0x74
      pattern == 41 and index == 0 -> 0x652E7865
      pattern == 41 and index == 1 -> 0x656D756E
      pattern == 41 and index == 2 -> 0x6C626172
      pattern == 41 and index == 3 -> 0x6F745F65
      pattern == 41 and index == 4 -> 0x73696C5F
      pattern == 41 and index == 5 -> 0x61725F74
      pattern == 41 and index == 6 -> 0x65676E
      pattern == 42 and index == 0 -> 0x652E7865
      pattern == 42 and index == 1 -> 0x746978
      pattern == 43 and index == 0 -> 0x652E7865
      pattern == 43 and index == 1 -> 0x726F7078
      pattern == 43 and index == 2 -> 0x5F646574
      pattern == 43 and index == 3 -> 0x6E6F6C63
      pattern == 43 and index == 4 -> 0x65
      pattern == 44 and index == 0 -> 0x652E7865
      pattern == 44 and index == 1 -> 0x726F7078
      pattern == 44 and index == 2 -> 0x5F646574
      pattern == 44 and index == 3 -> 0x74736564
      pattern == 44 and index == 4 -> 0x796F72
      pattern == 45 and index == 0 -> 0x652E7865
      pattern == 45 and index == 1 -> 0x726F7078
      pattern == 45 and index == 2 -> 0x5F646574
      pattern == 45 and index == 3 -> 0x746567
      pattern == 46 and index == 0 -> 0x652E7865
      pattern == 46 and index == 1 -> 0x726F7078
      pattern == 46 and index == 2 -> 0x5F646574
      pattern == 46 and index == 3 -> 0x676E656C
      pattern == 46 and index == 4 -> 0x6874
      pattern == 47 and index == 0 -> 0x662E7865
      pattern == 47 and index == 1 -> 0x5F656C69
      pattern == 47 and index == 2 -> 0x64616572
      pattern == 48 and index == 0 -> 0x662E7865
      pattern == 48 and index == 1 -> 0x5F656C69
      pattern == 48 and index == 2 -> 0x64616572
      pattern == 48 and index == 3 -> 0x6E696C5F
      pattern == 48 and index == 4 -> 0x7365
      pattern == 49 and index == 0 -> 0x662E7865
      pattern == 49 and index == 1 -> 0x74616F6C
      pattern == 49 and index == 2 -> 0x74696C5F
      pattern == 50 and index == 0 -> 0x662E7865
      pattern == 50 and index == 1 -> 0x74616F6C
      pattern == 50 and index == 2 -> 0x5F6F745F
      pattern == 50 and index == 3 -> 0x616E6962
      pattern == 50 and index == 4 -> 0x735F7972
      pattern == 50 and index == 5 -> 0x74726F68
      pattern == 51 and index == 0 -> 0x662E7865
      pattern == 51 and index == 1 -> 0x615F6E75
      pattern == 51 and index == 2 -> 0x79746972
      pattern == 52 and index == 0 -> 0x662E7865
      pattern == 52 and index == 1 -> 0x725F6E75
      pattern == 52 and index == 2 -> 0x6C757365
      pattern == 52 and index == 3 -> 0x6F6D5F74
      pattern == 52 and index == 4 -> 0x6564
      pattern == 53 and index == 0 -> 0x662E7865
      pattern == 53 and index == 1 -> 0x636E75
      pattern == 54 and index == 0 -> 0x662E7865
      pattern == 54 and index == 1 -> 0x5F636E75
      pattern == 54 and index == 2 -> 0x72646461
      pattern == 55 and index == 0 -> 0x692E7865
      pattern == 55 and index == 1 -> 0x66
      pattern == 56 and index == 0 -> 0x692E7865
      pattern == 56 and index == 1 -> 0x745F746E
      pattern == 56 and index == 2 -> 0x65685F6F
      pattern == 56 and index == 3 -> 0x78
      pattern == 57 and index == 0 -> 0x692E7865
      pattern == 57 and index == 1 -> 0x745F746E
      pattern == 57 and index == 2 -> 0x74735F6F
      pattern == 57 and index == 3 -> 0x676E6972
      pattern == 58 and index == 0 -> 0x692E7865
      pattern == 58 and index == 1 -> 0x745F746E
      pattern == 58 and index == 2 -> 0x74735F6F
      pattern == 58 and index == 3 -> 0x676E6972
      pattern == 58 and index == 4 -> 0x7361625F
      pattern == 58 and index == 5 -> 0x65
      pattern == 59 and index == 0 -> 0x692E7865
      pattern == 59 and index == 1 -> 0x7461646F
      pattern == 59 and index == 2 -> 0x6F745F61
      pattern == 59 and index == 3 -> 0x6E69625F
      pattern == 59 and index == 4 -> 0x797261
      pattern == 60 and index == 0 -> 0x692E7865
      pattern == 60 and index == 1 -> 0x74615F73
      pattern == 60 and index == 2 -> 0x6D6F
      pattern == 61 and index == 0 -> 0x692E7865
      pattern == 61 and index == 1 -> 0x69625F73
      pattern == 61 and index == 2 -> 0x7972616E
      pattern == 62 and index == 0 -> 0x692E7865
      pattern == 62 and index == 1 -> 0x6C665F73
      pattern == 62 and index == 2 -> 0x74616F
      pattern == 63 and index == 0 -> 0x692E7865
      pattern == 63 and index == 1 -> 0x6E695F73
      pattern == 63 and index == 2 -> 0x65676574
      pattern == 63 and index == 3 -> 0x72
      pattern == 64 and index == 0 -> 0x692E7865
      pattern == 64 and index == 1 -> 0x696C5F73
      pattern == 64 and index == 2 -> 0x7473
      pattern == 65 and index == 0 -> 0x692E7865
      pattern == 65 and index == 1 -> 0x616D5F73
      pattern == 65 and index == 2 -> 0x70
      pattern == 66 and index == 0 -> 0x692E7865
      pattern == 66 and index == 1 -> 0x75745F73
      pattern == 66 and index == 2 -> 0x656C70
      pattern == 67 and index == 0 -> 0x6C2E7865
      pattern == 67 and index == 1 -> 0x6B6E69
      pattern == 68 and index == 0 -> 0x6C2E7865
      pattern == 68 and index == 1 -> 0x747369
      pattern == 69 and index == 0 -> 0x6C2E7865
      pattern == 69 and index == 1 -> 0x5F747369
      pattern == 69 and index == 2 -> 0x736E6F63
      pattern == 70 and index == 0 -> 0x6C2E7865
      pattern == 70 and index == 1 -> 0x5F747369
      pattern == 70 and index == 2 -> 0x74616C66
      pattern == 70 and index == 3 -> 0x6E6574
      pattern == 71 and index == 0 -> 0x6C2E7865
      pattern == 71 and index == 1 -> 0x5F747369
      pattern == 71 and index == 2 -> 0x746567
      pattern == 72 and index == 0 -> 0x6C2E7865
      pattern == 72 and index == 1 -> 0x5F747369
      pattern == 72 and index == 2 -> 0x64616568
      pattern == 73 and index == 0 -> 0x6C2E7865
      pattern == 73 and index == 1 -> 0x5F747369
      pattern == 73 and index == 2 -> 0x676E656C
      pattern == 73 and index == 3 -> 0x6874
      pattern == 74 and index == 0 -> 0x6C2E7865
      pattern == 74 and index == 1 -> 0x5F747369
      pattern == 74 and index == 2 -> 0x6C696174
      pattern == 75 and index == 0 -> 0x6C2E7865
      pattern == 75 and index == 1 -> 0x7469
      pattern == 76 and index == 0 -> 0x6D2E7865
      pattern == 76 and index == 1 -> 0x626C6961
      pattern == 76 and index == 2 -> 0x635F786F
      pattern == 76 and index == 3 -> 0x7261656C
      pattern == 77 and index == 0 -> 0x6D2E7865
      pattern == 77 and index == 1 -> 0x626C6961
      pattern == 77 and index == 2 -> 0x6C5F786F
      pattern == 77 and index == 3 -> 0x6E65
      pattern == 78 and index == 0 -> 0x6D2E7865
      pattern == 78 and index == 1 -> 0x626C6961
      pattern == 78 and index == 2 -> 0x705F786F
      pattern == 78 and index == 3 -> 0x6B6565
      pattern == 79 and index == 0 -> 0x6D2E7865
      pattern == 79 and index == 1 -> 0x626C6961
      pattern == 79 and index == 2 -> 0x725F786F
      pattern == 79 and index == 3 -> 0x766F6D65
      pattern == 79 and index == 4 -> 0x65
      pattern == 80 and index == 0 -> 0x6D2E7865
      pattern == 80 and index == 1 -> 0x5F656B61
      pattern == 80 and index == 2 -> 0x6E7566
      pattern == 81 and index == 0 -> 0x6D2E7865
      pattern == 81 and index == 1 -> 0x5F656B61
      pattern == 81 and index == 2 -> 0x5F6E7566
      pattern == 81 and index == 3 -> 0x68746977
      pattern == 81 and index == 4 -> 0x6972615F
      pattern == 81 and index == 5 -> 0x7974
      pattern == 82 and index == 0 -> 0x6D2E7865
      pattern == 82 and index == 1 -> 0x5F656B61
      pattern == 82 and index == 2 -> 0x5F6E7566
      pattern == 82 and index == 3 -> 0x68746977
      pattern == 82 and index == 4 -> 0x6769735F
      pattern == 82 and index == 5 -> 0x7574616E
      pattern == 82 and index == 6 -> 0x6572
      pattern == 83 and index == 0 -> 0x6D2E7865
      pattern == 83 and index == 1 -> 0x7061
      pattern == 84 and index == 0 -> 0x6D2E7865
      pattern == 84 and index == 1 -> 0x665F7061
      pattern == 84 and index == 2 -> 0x68637465
      pattern == 85 and index == 0 -> 0x6D2E7865
      pattern == 85 and index == 1 -> 0x6C5F7061
      pattern == 85 and index == 2 -> 0x74676E65
      pattern == 85 and index == 3 -> 0x68
      pattern == 86 and index == 0 -> 0x6D2E7865
      pattern == 86 and index == 1 -> 0x705F7061
      pattern == 86 and index == 2 -> 0x7475
      pattern == 87 and index == 0 -> 0x6D2E7865
      pattern == 87 and index == 1 -> 0x65737061
      pattern == 87 and index == 2 -> 0x72665F74
      pattern == 87 and index == 3 -> 0x6C5F6D6F
      pattern == 87 and index == 4 -> 0x747369
      pattern == 88 and index == 0 -> 0x6D2E7865
      pattern == 88 and index == 1 -> 0x65737061
      pattern == 88 and index == 2 -> 0x656D5F74
      pattern == 88 and index == 3 -> 0x7265626D
      pattern == 89 and index == 0 -> 0x6D2E7865
      pattern == 89 and index == 1 -> 0x65737061
      pattern == 89 and index == 2 -> 0x75705F74
      pattern == 89 and index == 3 -> 0x74
      pattern == 90 and index == 0 -> 0x6D2E7865
      pattern == 90 and index == 1 -> 0x74696E6F
      pattern == 90 and index == 2 -> 0x726F
      pattern == 91 and index == 0 -> 0x6D2E7865
      pattern == 91 and index == 1 -> 0x746F6E6F
      pattern == 91 and index == 2 -> 0x63696E6F
      pattern == 91 and index == 3 -> 0x6D69745F
      pattern == 91 and index == 4 -> 0x65
      pattern == 92 and index == 0 -> 0x6D2E7865
      pattern == 92 and index == 1 -> 0x6C75
      pattern == 93 and index == 0 -> 0x6E2E7865
      pattern == 93 and index == 1 -> 0x76697461
      pattern == 93 and index == 2 -> 0x69745F65
      pattern == 93 and index == 3 -> 0x656D
      pattern == 94 and index == 0 -> 0x6E2E7865
      pattern == 94 and index == 1 -> 0x775F6C69
      pattern == 94 and index == 2 -> 0x64726F
      pattern == 95 and index == 0 -> 0x702E7865
      pattern == 95 and index == 1 -> 0x65636F72
      pattern == 95 and index == 2 -> 0x645F7373
      pattern == 95 and index == 3 -> 0x656E6F
      pattern == 96 and index == 0 -> 0x702E7865
      pattern == 96 and index == 1 -> 0x65636F72
      pattern == 96 and index == 2 -> 0x655F7373
      pattern == 96 and index == 3 -> 0x746978
      pattern == 97 and index == 0 -> 0x702E7865
      pattern == 97 and index == 1 -> 0x65636F72
      pattern == 97 and index == 2 -> 0x655F7373
      pattern == 97 and index == 3 -> 0x5F746978
      pattern == 97 and index == 4 -> 0x73616572
      pattern == 97 and index == 5 -> 0x6E6F
      pattern == 98 and index == 0 -> 0x702E7865
      pattern == 98 and index == 1 -> 0x65636F72
      pattern == 98 and index == 2 -> 0x725F7373
      pattern == 98 and index == 3 -> 0x6C757365
      pattern == 98 and index == 4 -> 0x74
      pattern == 99 and index == 0 -> 0x702E7865
      pattern == 99 and index == 1 -> 0x65636F72
      pattern == 99 and index == 2 -> 0x745F7373
      pattern == 99 and index == 3 -> 0x656C6261
      pattern == 99 and index == 4 -> 0x7365725F
      pattern == 99 and index == 5 -> 0x7465
      pattern == 100 and index == 0 -> 0x702E7865
      pattern == 100 and index == 1 -> 0x65636F72
      pattern == 100 and index == 2 -> 0x745F7373
      pattern == 100 and index == 3 -> 0x5F706172
      pattern == 100 and index == 4 -> 0x74697865
      pattern == 101 and index == 0 -> 0x702E7865
      pattern == 101 and index == 1 -> 0x65636F72
      pattern == 101 and index == 2 -> 0x775F7373
      pattern == 101 and index == 3 -> 0x746961
      pattern == 102 and index == 0 -> 0x702E7865
      pattern == 102 and index == 1 -> 0x65636F72
      pattern == 102 and index == 2 -> 0x73657373
      pattern == 102 and index == 3 -> 0x6E75725F
      pattern == 102 and index == 4 -> 0x6C62616E
      pattern == 102 and index == 5 -> 0x65
      pattern == 103 and index == 0 -> 0x722E7865
      pattern == 103 and index == 1 -> 0x65736961
      pattern == 104 and index == 0 -> 0x722E7865
      pattern == 104 and index == 1 -> 0x69656365
      pattern == 104 and index == 2 -> 0x6576
      pattern == 105 and index == 0 -> 0x722E7865
      pattern == 105 and index == 1 -> 0x69656365
      pattern == 105 and index == 2 -> 0x635F6576
      pattern == 105 and index == 3 -> 0x5F746E6F
      pattern == 105 and index == 4 -> 0x65766173
      pattern == 106 and index == 0 -> 0x722E7865
      pattern == 106 and index == 1 -> 0x69656365
      pattern == 106 and index == 2 -> 0x735F6576
      pattern == 106 and index == 3 -> 0x74726174
      pattern == 107 and index == 0 -> 0x722E7865
      pattern == 107 and index == 1 -> 0x69656365
      pattern == 107 and index == 2 -> 0x735F6576
      pattern == 107 and index == 3 -> 0x74726174
      pattern == 107 and index == 4 -> 0x7465735F
      pattern == 108 and index == 0 -> 0x722E7865
      pattern == 108 and index == 1 -> 0x63756465
      pattern == 108 and index == 2 -> 0x6E6F6974
      pattern == 108 and index == 3 -> 0x6369745F
      pattern == 108 and index == 4 -> 0x6B
      pattern == 109 and index == 0 -> 0x722E7865
      pattern == 109 and index == 1 -> 0x6D65
      pattern == 110 and index == 0 -> 0x722E7865
      pattern == 110 and index == 1 -> 0x6C757365
      pattern == 110 and index == 2 -> 0x74615F74
      pattern == 110 and index == 3 -> 0x6E5F6D6F
      pattern == 110 and index == 4 -> 0x656D61
      pattern == 111 and index == 0 -> 0x722E7865
      pattern == 111 and index == 1 -> 0x6C757365
      pattern == 111 and index == 2 -> 0x72635F74
      pattern == 111 and index == 3 -> 0x65746165
      pattern == 112 and index == 0 -> 0x722E7865
      pattern == 112 and index == 1 -> 0x6C757365
      pattern == 112 and index == 2 -> 0x65645F74
      pattern == 112 and index == 3 -> 0x6F727473
      pattern == 112 and index == 4 -> 0x79
      pattern == 113 and index == 0 -> 0x722E7865
      pattern == 113 and index == 1 -> 0x6C757365
      pattern == 113 and index == 2 -> 0x78655F74
      pattern == 113 and index == 3 -> 0x74706563
      pattern == 113 and index == 4 -> 0x5F6E6F69
      pattern == 113 and index == 5 -> 0x646E696B
      pattern == 114 and index == 0 -> 0x722E7865
      pattern == 114 and index == 1 -> 0x6C757365
      pattern == 114 and index == 2 -> 0x78655F74
      pattern == 114 and index == 3 -> 0x74706563
      pattern == 114 and index == 4 -> 0x5F6E6F69
      pattern == 114 and index == 5 -> 0x73616572
      pattern == 114 and index == 6 -> 0x6E6F
      pattern == 115 and index == 0 -> 0x722E7865
      pattern == 115 and index == 1 -> 0x6C757365
      pattern == 115 and index == 2 -> 0x6F725F74
      pattern == 115 and index == 3 -> 0x6B5F746F
      pattern == 115 and index == 4 -> 0x646E69
      pattern == 116 and index == 0 -> 0x722E7865
      pattern == 116 and index == 1 -> 0x6C757365
      pattern == 116 and index == 2 -> 0x6F725F74
      pattern == 116 and index == 3 -> 0x775F746F
      pattern == 116 and index == 4 -> 0x64726F
      pattern == 117 and index == 0 -> 0x722E7865
      pattern == 117 and index == 1 -> 0x6C757365
      pattern == 117 and index == 2 -> 0x65745F74
      pattern == 117 and index == 3 -> 0x675F6D72
      pattern == 117 and index == 4 -> 0x7465
      pattern == 118 and index == 0 -> 0x722E7865
      pattern == 118 and index == 1 -> 0x6C757365
      pattern == 118 and index == 2 -> 0x65745F74
      pattern == 118 and index == 3 -> 0x6B5F6D72
      pattern == 118 and index == 4 -> 0x646E69
      pattern == 119 and index == 0 -> 0x722E7865
      pattern == 119 and index == 1 -> 0x6C757365
      pattern == 119 and index == 2 -> 0x65745F74
      pattern == 119 and index == 3 -> 0x6C5F6D72
      pattern == 119 and index == 4 -> 0x74676E65
      pattern == 119 and index == 5 -> 0x68
      pattern == 120 and index == 0 -> 0x722E7865
      pattern == 120 and index == 1 -> 0x72757465
      pattern == 120 and index == 2 -> 0x6E
      pattern == 121 and index == 0 -> 0x722E7865
      pattern == 121 and index == 1 -> 0x69746E75
      pattern == 121 and index == 2 -> 0x635F656D
      pattern == 121 and index == 3 -> 0x74616572
      pattern == 121 and index == 4 -> 0x65
      pattern == 122 and index == 0 -> 0x722E7865
      pattern == 122 and index == 1 -> 0x69746E75
      pattern == 122 and index == 2 -> 0x645F656D
      pattern == 122 and index == 3 -> 0x72747365
      pattern == 122 and index == 4 -> 0x796F
      pattern == 123 and index == 0 -> 0x722E7865
      pattern == 123 and index == 1 -> 0x69746E75
      pattern == 123 and index == 2 -> 0x655F656D
      pattern == 123 and index == 3 -> 0x7265746E
      pattern == 124 and index == 0 -> 0x722E7865
      pattern == 124 and index == 1 -> 0x69746E75
      pattern == 124 and index == 2 -> 0x6C5F656D
      pattern == 124 and index == 3 -> 0x65766165
      pattern == 125 and index == 0 -> 0x732E7865
      pattern == 125 and index == 1 -> 0x64656863
      pattern == 125 and index == 2 -> 0x5F656C75
      pattern == 125 and index == 3 -> 0x7478656E
      pattern == 126 and index == 0 -> 0x732E7865
      pattern == 126 and index == 1 -> 0x666C65
      pattern == 127 and index == 0 -> 0x732E7865
      pattern == 127 and index == 1 -> 0x646E65
      pattern == 128 and index == 0 -> 0x732E7865
      pattern == 128 and index == 1 -> 0x6E776170
      pattern == 129 and index == 0 -> 0x732E7865
      pattern == 129 and index == 1 -> 0x61657274
      pattern == 129 and index == 2 -> 0x72645F6D
      pattern == 129 and index == 3 -> 0x706F
      pattern == 130 and index == 0 -> 0x732E7865
      pattern == 130 and index == 1 -> 0x61657274
      pattern == 130 and index == 2 -> 0x69665F6D
      pattern == 130 and index == 3 -> 0x7265746C
      pattern == 131 and index == 0 -> 0x732E7865
      pattern == 131 and index == 1 -> 0x61657274
      pattern == 131 and index == 2 -> 0x61745F6D
      pattern == 131 and index == 3 -> 0x656B
      pattern == 132 and index == 0 -> 0x732E7865
      pattern == 132 and index == 1 -> 0x6E697274
      pattern == 132 and index == 2 -> 0x72705F67
      pattern == 132 and index == 3 -> 0x61746E69
      pattern == 132 and index == 4 -> 0x656C62
      pattern == 133 and index == 0 -> 0x732E7865
      pattern == 133 and index == 1 -> 0x6E697274
      pattern == 133 and index == 2 -> 0x6F745F67
      pattern == 133 and index == 3 -> 0x6F74615F
      pattern == 133 and index == 4 -> 0x6D
      pattern == 134 and index == 0 -> 0x732E7865
      pattern == 134 and index == 1 -> 0x6E697274
      pattern == 134 and index == 2 -> 0x6F745F67
      pattern == 134 and index == 3 -> 0x6978655F
      pattern == 134 and index == 4 -> 0x6E697473
      pattern == 134 and index == 5 -> 0x74615F67
      pattern == 134 and index == 6 -> 0x6D6F
      pattern == 135 and index == 0 -> 0x732E7865
      pattern == 135 and index == 1 -> 0x6E697274
      pattern == 135 and index == 2 -> 0x6F745F67
      pattern == 135 and index == 3 -> 0x6F6C665F
      pattern == 135 and index == 4 -> 0x7461
      pattern == 136 and index == 0 -> 0x732E7865
      pattern == 136 and index == 1 -> 0x6E697274
      pattern == 136 and index == 2 -> 0x6F745F67
      pattern == 136 and index == 3 -> 0x746E695F
      pattern == 137 and index == 0 -> 0x732E7865
      pattern == 137 and index == 1 -> 0x6275
      pattern == 138 and index == 0 -> 0x742E7865
      pattern == 138 and index == 1 -> 0x5F6D7265
      pattern == 138 and index == 2 -> 0x7165
      pattern == 139 and index == 0 -> 0x742E7865
      pattern == 139 and index == 1 -> 0x5F6D7265
      pattern == 139 and index == 2 -> 0x6C5F7165
      pattern == 139 and index == 3 -> 0x65736F6F
      pattern == 140 and index == 0 -> 0x742E7865
      pattern == 140 and index == 1 -> 0x5F6D7265
      pattern == 140 and index == 2 -> 0x6F707865
      pattern == 140 and index == 3 -> 0x7472
      pattern == 141 and index == 0 -> 0x742E7865
      pattern == 141 and index == 1 -> 0x5F6D7265
      pattern == 141 and index == 2 -> 0x646E6168
      pattern == 141 and index == 3 -> 0x645F656C
      pattern == 141 and index == 4 -> 0x72747365
      pattern == 141 and index == 5 -> 0x796F
      pattern == 142 and index == 0 -> 0x742E7865
      pattern == 142 and index == 1 -> 0x5F6D7265
      pattern == 142 and index == 2 -> 0x646E6168
      pattern == 142 and index == 3 -> 0x655F656C
      pattern == 142 and index == 4 -> 0x726F7078
      pattern == 142 and index == 5 -> 0x74
      pattern == 143 and index == 0 -> 0x742E7865
      pattern == 143 and index == 1 -> 0x5F6D7265
      pattern == 143 and index == 2 -> 0x6F706D69
      pattern == 143 and index == 3 -> 0x7472
      pattern == 144 and index == 0 -> 0x742E7865
      pattern == 144 and index == 1 -> 0x776F7268
      pattern == 145 and index == 0 -> 0x742E7865
      pattern == 145 and index == 1 -> 0x6E695F6F
      pattern == 145 and index == 2 -> 0x74
      pattern == 146 and index == 0 -> 0x742E7865
      pattern == 146 and index == 1 -> 0x6F775F6F
      pattern == 146 and index == 2 -> 0x6472
      pattern == 147 and index == 0 -> 0x742E7865
      pattern == 147 and index == 1 -> 0x7972
      pattern == 148 and index == 0 -> 0x742E7865
      pattern == 148 and index == 1 -> 0x656C7075
      pattern == 149 and index == 0 -> 0x742E7865
      pattern == 149 and index == 1 -> 0x656C7075
      pattern == 149 and index == 2 -> 0x7465675F
      pattern == 150 and index == 0 -> 0x742E7865
      pattern == 150 and index == 1 -> 0x656C7075
      pattern == 150 and index == 2 -> 0x6E656C5F
      pattern == 150 and index == 3 -> 0x687467
      pattern == 151 and index == 0 -> 0x752E7865
      pattern == 151 and index == 1 -> 0x786F626E
      pattern == 152 and index == 0 -> 0x752E7865
      pattern == 152 and index == 1 -> 0x7571696E
      pattern == 152 and index == 2 -> 0x6E695F65
      pattern == 152 and index == 3 -> 0x65676574
      pattern == 152 and index == 4 -> 0x72
      pattern == 153 and index == 0 -> 0x752E7865
      pattern == 153 and index == 1 -> 0x6E696C6E
      pattern == 153 and index == 2 -> 0x6B
      pattern == 154 and index == 0 -> 0x762E7865
      pattern == 154 and index == 1 -> 0x7261
      pattern == 155 and index == 0 -> 0x772E7865
      pattern == 155 and index == 1 -> 0x656B726F
      pattern == 155 and index == 2 -> 0x75725F72
      pattern == 155 and index == 3 -> 0x6E
      pattern == 156 and index == 0 -> 0x792E7865
      pattern == 156 and index == 1 -> 0x646C6569
      pattern == 157 and index == 0 -> 0x792E7865
      pattern == 157 and index == 1 -> 0x646C6569
      pattern == 157 and index == 2 -> 0x72616D5F
      pattern == 157 and index == 3 -> 0x6B
      true -> -1
    end
  end

  def pattern_target(pattern) do
    cond do
      pattern == 0 -> 2
      pattern == 1 -> 157
      pattern == 2 -> 0
      pattern == 3 -> 111
      pattern == 4 -> 110
      pattern == 5 -> 14
      pattern == 6 -> 103
      pattern == 7 -> 102
      pattern == 8 -> 12
      pattern == 9 -> 109
      pattern == 10 -> 104
      pattern == 11 -> 105
      pattern == 12 -> 107
      pattern == 13 -> 106
      pattern == 14 -> 0
      pattern == 15 -> 10
      pattern == 16 -> 138
      pattern == 17 -> 68
      pattern == 18 -> 7
      pattern == 19 -> 63
      pattern == 20 -> 64
      pattern == 21 -> 66
      pattern == 22 -> 65
      pattern == 23 -> 67
      pattern == 24 -> 62
      pattern == 25 -> 60
      pattern == 26 -> 48
      pattern == 27 -> 57
      pattern == 28 -> 5
      pattern == 29 -> 118
      pattern == 30 -> 130
      pattern == 31 -> 121
      pattern == 32 -> 120
      pattern == 33 -> 127
      pattern == 34 -> 128
      pattern == 35 -> 129
      pattern == 36 -> 123
      pattern == 37 -> 124
      pattern == 38 -> 126
      pattern == 39 -> 125
      pattern == 40 -> 119
      pattern == 41 -> 122
      pattern == 42 -> 55
      pattern == 43 -> 35
      pattern == 44 -> 36
      pattern == 45 -> 38
      pattern == 46 -> 37
      pattern == 47 -> 116
      pattern == 48 -> 117
      pattern == 49 -> 97
      pattern == 50 -> 101
      pattern == 51 -> 134
      pattern == 52 -> 135
      pattern == 53 -> 18
      pattern == 54 -> 158
      pattern == 55 -> 16
      pattern == 56 -> 114
      pattern == 57 -> 112
      pattern == 58 -> 113
      pattern == 59 -> 96
      pattern == 60 -> 144
      pattern == 61 -> 145
      pattern == 62 -> 143
      pattern == 63 -> 142
      pattern == 64 -> 146
      pattern == 65 -> 148
      pattern == 66 -> 147
      pattern == 67 -> 53
      pattern == 68 -> 149
      pattern == 69 -> 13
      pattern == 70 -> 82
      pattern == 71 -> 85
      pattern == 72 -> 83
      pattern == 73 -> 86
      pattern == 74 -> 84
      pattern == 75 -> 1
      pattern == 76 -> 45
      pattern == 77 -> 71
      pattern == 78 -> 72
      pattern == 79 -> 73
      pattern == 80 -> 152
      pattern == 81 -> 153
      pattern == 82 -> 154
      pattern == 83 -> 151
      pattern == 84 -> 89
      pattern == 85 -> 91
      pattern == 86 -> 90
      pattern == 87 -> 92
      pattern == 88 -> 93
      pattern == 89 -> 94
      pattern == 90 -> 56
      pattern == 91 -> 75
      pattern == 92 -> 4
      pattern == 93 -> 78
      pattern == 94 -> 74
      pattern == 95 -> 49
      pattern == 96 -> 50
      pattern == 97 -> 51
      pattern == 98 -> 59
      pattern == 99 -> 41
      pattern == 100 -> 52
      pattern == 101 -> 136
      pattern == 102 -> 58
      pattern == 103 -> 140
      pattern == 104 -> 44
      pattern == 105 -> 61
      pattern == 106 -> 76
      pattern == 107 -> 77
      pattern == 108 -> 69
      pattern == 109 -> 6
      pattern == 110 -> 30
      pattern == 111 -> 23
      pattern == 112 -> 24
      pattern == 113 -> 27
      pattern == 114 -> 28
      pattern == 115 -> 25
      pattern == 116 -> 26
      pattern == 117 -> 32
      pattern == 118 -> 29
      pattern == 119 -> 31
      pattern == 120 -> 17
      pattern == 121 -> 19
      pattern == 122 -> 22
      pattern == 123 -> 20
      pattern == 124 -> 21
      pattern == 125 -> 47
      pattern == 126 -> 42
      pattern == 127 -> 43
      pattern == 128 -> 46
      pattern == 129 -> 133
      pattern == 130 -> 131
      pattern == 131 -> 132
      pattern == 132 -> 108
      pattern == 133 -> 99
      pattern == 134 -> 100
      pattern == 135 -> 98
      pattern == 136 -> 115
      pattern == 137 -> 3
      pattern == 138 -> 11
      pattern == 139 -> 81
      pattern == 140 -> 33
      pattern == 141 -> 40
      pattern == 142 -> 39
      pattern == 143 -> 34
      pattern == 144 -> 139
      pattern == 145 -> 80
      pattern == 146 -> 0
      pattern == 147 -> 0
      pattern == 148 -> 150
      pattern == 149 -> 87
      pattern == 150 -> 88
      pattern == 151 -> 0
      pattern == 152 -> 79
      pattern == 153 -> 54
      pattern == 154 -> 0
      pattern == 155 -> 137
      pattern == 156 -> 9
      pattern == 157 -> 70
      true -> -1
    end
  end

  def pattern_action(pattern) do
    cond do
      pattern == 0 -> 3
      pattern == 1 -> 2
      pattern == 2 -> 4
      pattern == 3 -> 16
      pattern == 4 -> 16
      pattern == 5 -> 16
      pattern == 6 -> 16
      pattern == 7 -> 16
      pattern == 8 -> 16
      pattern == 9 -> 16
      pattern == 10 -> 16
      pattern == 11 -> 16
      pattern == 12 -> 16
      pattern == 13 -> 16
      pattern == 14 -> 5
      pattern == 15 -> 6
      pattern == 16 -> 16
      pattern == 17 -> 16
      pattern == 18 -> 7
      pattern == 19 -> 16
      pattern == 20 -> 16
      pattern == 21 -> 16
      pattern == 22 -> 16
      pattern == 23 -> 16
      pattern == 24 -> 16
      pattern == 25 -> 16
      pattern == 26 -> 16
      pattern == 27 -> 16
      pattern == 28 -> 3
      pattern == 29 -> 16
      pattern == 30 -> 16
      pattern == 31 -> 16
      pattern == 32 -> 16
      pattern == 33 -> 16
      pattern == 34 -> 16
      pattern == 35 -> 16
      pattern == 36 -> 16
      pattern == 37 -> 16
      pattern == 38 -> 16
      pattern == 39 -> 16
      pattern == 40 -> 16
      pattern == 41 -> 16
      pattern == 42 -> 16
      pattern == 43 -> 16
      pattern == 44 -> 16
      pattern == 45 -> 16
      pattern == 46 -> 16
      pattern == 47 -> 16
      pattern == 48 -> 16
      pattern == 49 -> 16
      pattern == 50 -> 16
      pattern == 51 -> 16
      pattern == 52 -> 16
      pattern == 53 -> 9
      pattern == 54 -> 8
      pattern == 55 -> 12
      pattern == 56 -> 16
      pattern == 57 -> 16
      pattern == 58 -> 16
      pattern == 59 -> 16
      pattern == 60 -> 14
      pattern == 61 -> 14
      pattern == 62 -> 14
      pattern == 63 -> 14
      pattern == 64 -> 14
      pattern == 65 -> 14
      pattern == 66 -> 14
      pattern == 67 -> 16
      pattern == 68 -> 1
      pattern == 69 -> 16
      pattern == 70 -> 16
      pattern == 71 -> 16
      pattern == 72 -> 16
      pattern == 73 -> 16
      pattern == 74 -> 16
      pattern == 75 -> 13
      pattern == 76 -> 16
      pattern == 77 -> 16
      pattern == 78 -> 16
      pattern == 79 -> 16
      pattern == 80 -> 10
      pattern == 81 -> 10
      pattern == 82 -> 10
      pattern == 83 -> 1
      pattern == 84 -> 16
      pattern == 85 -> 16
      pattern == 86 -> 16
      pattern == 87 -> 16
      pattern == 88 -> 16
      pattern == 89 -> 16
      pattern == 90 -> 16
      pattern == 91 -> 16
      pattern == 92 -> 3
      pattern == 93 -> 16
      pattern == 94 -> 16
      pattern == 95 -> 16
      pattern == 96 -> 16
      pattern == 97 -> 16
      pattern == 98 -> 16
      pattern == 99 -> 16
      pattern == 100 -> 16
      pattern == 101 -> 16
      pattern == 102 -> 16
      pattern == 103 -> 16
      pattern == 104 -> 16
      pattern == 105 -> 16
      pattern == 106 -> 16
      pattern == 107 -> 16
      pattern == 108 -> 16
      pattern == 109 -> 3
      pattern == 110 -> 16
      pattern == 111 -> 16
      pattern == 112 -> 16
      pattern == 113 -> 16
      pattern == 114 -> 16
      pattern == 115 -> 16
      pattern == 116 -> 16
      pattern == 117 -> 16
      pattern == 118 -> 16
      pattern == 119 -> 16
      pattern == 120 -> 15
      pattern == 121 -> 16
      pattern == 122 -> 16
      pattern == 123 -> 16
      pattern == 124 -> 16
      pattern == 125 -> 16
      pattern == 126 -> 16
      pattern == 127 -> 16
      pattern == 128 -> 16
      pattern == 129 -> 16
      pattern == 130 -> 16
      pattern == 131 -> 16
      pattern == 132 -> 16
      pattern == 133 -> 16
      pattern == 134 -> 16
      pattern == 135 -> 16
      pattern == 136 -> 16
      pattern == 137 -> 3
      pattern == 138 -> 16
      pattern == 139 -> 16
      pattern == 140 -> 16
      pattern == 141 -> 16
      pattern == 142 -> 16
      pattern == 143 -> 16
      pattern == 144 -> 16
      pattern == 145 -> 16
      pattern == 146 -> 11
      pattern == 147 -> 17
      pattern == 148 -> 1
      pattern == 149 -> 16
      pattern == 150 -> 16
      pattern == 151 -> 11
      pattern == 152 -> 16
      pattern == 153 -> 16
      pattern == 154 -> 18
      pattern == 155 -> 16
      pattern == 156 -> 19
      pattern == 157 -> 16
      true -> -1
    end
  end

  def try_accept(operands, results, regions, body_arguments, catch_arguments) do
    Bitwise.band(
      Bitwise.band(operands == 0, results == 1),
      Bitwise.band(
        regions == 2,
        Bitwise.band(body_arguments == 0, catch_arguments == 0)
      )
    )
  end
end
