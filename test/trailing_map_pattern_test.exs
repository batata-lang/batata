defmodule Batata.TrailingMapPatternTest do
  use Batata.Case, async: true

  @source """
  defmodule TrailingMapPatternFixture do
    def route(:encode, %{pretty: true} = opts), do: {:pretty, opts}

    def route(:encode, %{pretty: pretty} = opts) when pretty !== false,
      do: {:custom, pretty, opts}

    def route(:encode, %{pretty: false} = opts), do: {:plain, opts}
    def route(_, _), do: :fallback

    def main() do
      {
        route(:encode, %{pretty: true, extra: 1}),
        route(:encode, %{pretty: :compact, extra: 2}),
        route(:encode, %{pretty: false}),
        route(:encode, %{other: true}),
        route(:encode, :not_a_map)
      }
    end
  end
  """

  test "matches and binds aliased atom-key maps in trailing arguments", %{ctx: ctx} do
    expected =
      @source
      |> Kernel.<>("\nTrailingMapPatternFixture.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "routes trailing maps through the existing subset matcher", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"ex.map_fetch"}
    assert ir =~ ~s{"ex.is_map"}
  end

  test "keeps non-atom map keys outside the trailing-pattern contract", %{ctx: ctx} do
    source = """
    defmodule UnsupportedTrailingMapKey do
      def route(:encode, %{"pretty" => true}), do: :pretty
      def route(_, _), do: :fallback
      def main(), do: route(:encode, %{"pretty" => true})
    end
    """

    assert_raise Batata.Lift.Error,
                 ~r/map patterns only support atom literal or pinned keys/,
                 fn ->
                   Batata.compile(source, ctx)
                 end
  end
end
