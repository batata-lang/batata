defmodule Batata.Probe.Jason.EncoderSubsetTest do
  @moduledoc """
  Executable encoder output shapes derived from Jason 1.4.5.

  Jason.encode/2 and encode!/2 flatten the nested iodata returned by
  Jason.Encode at the public binary boundary. These cases preserve that shape
  and compare Batata with the BEAM oracle.
  """

  use Batata.Jason.Case, async: true

  alias Batata
  alias Batata.Jason.Test.EncoderSubset

  @cases [
    {"nested object output", ["{", ["\"ok\"", ":", [?t, "rue"]], "}"], ~s({"ok":true})},
    {"mixed byte and binary leaves", [?a, ?b, "cd"], "abcd"},
    {"empty iodata", [], ""}
  ]

  for {name, iodata, expected} <- @cases do
    test name, %{ctx: ctx} do
      source = EncoderSubset.source(unquote(Macro.escape(iodata)))

      assert unquote(expected) == beam_result(source)
      assert unquote(expected) == Batata.execute(source, ctx)
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
