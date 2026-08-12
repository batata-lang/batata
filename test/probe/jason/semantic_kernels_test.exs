defmodule Batata.Probe.Jason.SemanticKernelsTest do
  @moduledoc """
  Jason-shaped minimized kernels that reach Batata execution.

  These are derived from the scanner shapes used by Jason 1.4.5, but remain
  Batata-owned test programs. They are not evidence that unmodified Jason
  modules compile; the source inventory reports that boundary separately.
  """

  use Batata.Case, async: true

  alias Batata

  @kernels [
    {"literal token recognition",
     """
     defmodule JasonTokenKernel do
       def main() do
         case <<116, 114, 117, 101, 33>> do
           <<116, 114, 117, 101, rest::binary>> -> byte_size(rest) + 10
           _ -> 0
         end
       end
     end
     """},
    {"decimal digit scanner",
     """
     defmodule JasonNumberKernel do
       def digits(<<>>, acc), do: acc
       def digits(<<_digit::8, rest::binary>>, acc), do: digits(rest, acc + 1)
       def digits(_rest, acc), do: acc
       def main(), do: digits(<<49, 50, 51, 52, 53>>, 0)
     end
     """},
    {"UTF-8 codepoint scanner",
     """
     defmodule JasonUtf8Kernel do
       def main() do
         case <<97, 0xC3, 0xA9, 0xE4, 0xB8, 0xAD>> do
           <<_char::utf8, rest::binary>> -> byte_size(rest)
           _ -> 0
         end
       end
     end
     """},
    {"escape marker scanner",
     """
     defmodule JasonEscapeKernel do
       def main() do
         case <<92, 34, 98>> do
           <<92, _escaped::8, rest::binary>> -> byte_size(rest) + 10
           _ -> 0
         end
       end
     end
     """}
  ]

  for {name, source} <- @kernels do
    test name, %{ctx: ctx} do
      source = unquote(source)
      assert Batata.execute(source, ctx) == beam_result(source)
    end
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
