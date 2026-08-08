defmodule BatataDiffCore do
  @moduledoc """
  Self-bootstrap fixture: the pure-slice core of Batata's upgrade diff logic,
  written in the batata-compilable subset.

  `classify/2` is a scalar stand-in for `Batata.Upgrade.Diff`'s file-status
  classification (unchanged / added / removed / changed, with 0 as the
  missing-sentinel), exercising multi-argument functions, term tuple patterns,
  equality guards, and scalar arithmetic end to end.
  """

  def main() do
    classify(1, 1) + classify(1, 2) * 10 + classify(0, 2) * 100 + classify(1, 0) * 1000
  end

  defp classify(old, new) do
    case {old, new} do
      {a, b} when a == b -> 1
      {0, _b} -> 2
      {_a, 0} -> 3
      _ -> 4
    end
  end
end
