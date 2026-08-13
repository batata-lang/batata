defmodule Batata.Probe.Jason.GuardByteSizeTest do
  @moduledoc """
  Executable `byte_size/1` guard kernels derived from Jason 1.4.5.

  These Batata-owned kernels isolate the guard semantics without claiming that
  Jason's original map-patterned `Jason.DecodeError.message/1` compiles.
  """

  use Batata.Case, async: true

  alias Batata

  @cases [
    {<<1, 2, 3>>, 3, :matched},
    {<<1, 2>>, 3, :fallback},
    {:not_a_binary, 0, :fallback}
  ]

  for {value, expected_size, expected} <- @cases do
    test "matches #{inspect(value)} against byte size #{expected_size}", %{ctx: ctx} do
      source = source(unquote(Macro.escape(value)), unquote(expected_size))

      assert unquote(expected) == beam_result(source)
      assert unquote(expected) == Batata.execute(source, ctx)
    end
  end

  defp source(value, expected_size) do
    """
    defmodule JasonByteSizeGuardKernel do
      def main() do
        case #{inspect(value)} do
          value when byte_size(value) == #{expected_size} -> :matched
          _value -> :fallback
        end
      end
    end
    """
  end

  defp beam_result(source) do
    [{module, _binary}] = Code.compile_string(source)

    try do
      module.main()
    after
      :code.purge(module)
      :code.delete(module)
    end
  end
end
