defmodule Batata.SemanticGatesTest do
  @moduledoc """
  M5 semantic gates (tsai/beaver#29): every gate compiles an Elixir subset
  program with Batata and asserts the result matches the BEAM oracle of the
  equivalent expression.
  """

  use Batata.Case, async: true

  alias Batata

  @gates [
    {"scalar arithmetic", "1 + 2 * 3 - 4", "1 + 2 * 3 - 4"},
    {"bindings", "a = 5\na * 2 + 1", "a = 5\na * 2 + 1"},
    {"scalar case", "case 3 do 1 -> 10; 3 -> 30; _ -> 0 end",
     "case 3 do 1 -> 10; 3 -> 30; _ -> 0 end"},
    {"term tuple pattern", "case {1, 2} do {a, b} -> tuple_size({a, b}); _ -> 0 end",
     "case {1, 2} do {a, b} -> tuple_size({a, b}); _ -> 0 end"},
    {"binary pattern", "case <<1, 2, 3>> do <<_h::8, t::binary>> -> byte_size(t) + 1; _ -> 0 end",
     "case <<1, 2, 3>> do <<_h::8, t::binary>> -> byte_size(t) + 1; _ -> 0 end"},
    {"cursor scanner", "count(<<1, 2, 3>>)", "byte_size(<<1, 2, 3>>)"},
    {"Kernel length", "length([1, 2, 3])", "length([1, 2, 3])"},
    {"Kernel tuple_size", "tuple_size({1, 2})", "tuple_size({1, 2})"},
    {"Kernel byte_size", "byte_size(<<1, 2, 3>>)", "byte_size(<<1, 2, 3>>)"},
    {"Enum count", "Enum.count([1, 2, 3])", "Enum.count([1, 2, 3])"},
    {"Enum reduce sum", "Enum.reduce([1, 2, 3], 0, fn x, a -> x + a end)",
     "Enum.reduce([1, 2, 3], 0, fn x, a -> x + a end)"},
    {"Enum map then reduce",
     "Enum.reduce(Enum.map([1, 2, 3], fn x -> x + 10 end), 0, fn x, a -> x + a end)",
     "Enum.reduce(Enum.map([1, 2, 3], fn x -> x + 10 end), 0, fn x, a -> x + a end)"},
    {"Enum/String pipeline",
     "Enum.reduce(Enum.map([1, 2, 3], fn x -> x + 10 end), String.to_integer(\"1\"), fn x, a -> x + a end)",
     "Enum.reduce(Enum.map([1, 2, 3], fn x -> x + 10 end), String.to_integer(\"1\"), fn x, a -> x + a end)"},
    {"Enum count in case",
     "case Enum.count(%{1 => 2, 3 => 4}) do 2 -> tuple_size({1, 2}); _ -> 0 end",
     "case Enum.count(%{1 => 2, 3 => 4}) do 2 -> tuple_size({1, 2}); _ -> 0 end"},
    {"String length utf8", "String.length(\"aé中\")", "String.length(\"aé中\")"},
    {"String/Integer roundtrip", "String.to_integer(Integer.to_string(42))",
     "String.to_integer(Integer.to_string(42))"},
    {"Base16 roundtrip", "byte_size(Base.decode16(Base.encode16(<<1, 2, 3>>)))",
     "byte_size(Base.decode16!(Base.encode16(<<1, 2, 3>>)))"},
    {"closure application", "f = fn x -> x + 1 end\nf.(2) + f.(3)",
     "f = fn x -> x + 1 end\nf.(2) + f.(3)"},
    {"receive", "pid = self()\nsend(pid, 42)\nreceive do 42 -> 43 end",
     "pid = self()\nsend(pid, 42)\nreceive do 42 -> 43 end"},
    {"receive in try", "try do pid = self(); send(pid, 7); receive do x -> x end catch _ -> 0 end",
     "try do pid = self(); send(pid, 7); receive do x -> x end catch _ -> 0 end"},
    {"try/throw", "try do throw(42) catch 42 -> 10 end", "try do throw(42) catch 42 -> 10 end"},
    {"try normal path", "try do 7 catch _ -> 0 end", "try do 7 catch _ -> 0 end"}
  ]

  for {label, expr, oracle} <- @gates do
    source = """
    defmodule Math do
      def main() do
        #{expr}
      end

      defp count(<<>>), do: 0
      defp count(<<_h::8, t::binary>>), do: 1 + count(t)
      defp count(_), do: 0
    end
    """

    test "gate: #{label}", %{ctx: ctx} do
      expected = unquote(oracle) |> Code.eval_string() |> elem(0)
      assert Batata.execute(unquote(source), ctx) == expected
    end
  end
end
