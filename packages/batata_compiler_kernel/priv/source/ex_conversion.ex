defmodule Batata.CompilerKernel.Native.ExConversion do
  def ex_add_decide(n_operands, has_result) do
    Bitwise.band(n_operands == 2, has_result == 1)
  end

  def ex_add_target_length(), do: 10
  def ex_add_target_word0(), do: 0x74697261
  def ex_add_target_word1(), do: 0x64612E68
  def ex_add_target_word2(), do: 0x6964
end
