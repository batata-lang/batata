defmodule Batata.Frontend.DefaultArgExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.DefaultArgExpand
  alias Batata.Frontend.DefaultArgExpand.Error

  test "expands non-trailing defaults into direct full-arity wrappers" do
    expanded =
      quote do
        defmodule Sample do
          def value(a \\ 1, b, c \\ 3), do: {a, b, c}
        end
      end
      |> DefaultArgExpand.expand()
      |> Macro.to_string()

    assert expanded =~ "def value(batata_arg0)"
    assert expanded =~ "value(1, batata_arg0, 3)"
    assert expanded =~ "def value(batata_arg0, batata_arg1)"
    assert expanded =~ "value(batata_arg0, batata_arg1, 3)"
    assert expanded =~ "def value(a, b, c)"
    refute expanded =~ "\\\\"
  end

  test "expands head-only defaults once for following clauses" do
    expanded =
      quote do
        defmodule Sample do
          def value(input \\ :default)
          def value(:default), do: 1
          def value(input), do: input
        end
      end
      |> DefaultArgExpand.expand()
      |> Macro.to_string()

    assert expanded =~ "def value()"
    assert expanded =~ "value(:default)"
    assert length(Regex.scan(~r/def value\(/, expanded)) == 3
    refute expanded =~ "\\\\"
  end

  test "matches BEAM evaluation timing, count, and order" do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    original = fixture(module)
    expanded = DefaultArgExpand.expand(original)

    Code.compile_quoted(original)
    assert invocation_trace(module) == [{{1, :middle, 3}, [:a, :c]}, {{:x, :middle, 3}, [:c]}]

    :code.purge(module)
    :code.delete(module)

    Code.compile_quoted(expanded)
    assert invocation_trace(module) == [{{1, :middle, 3}, [:a, :c]}, {{:x, :middle, 3}, [:c]}]
  end

  test "rejects defaults that reference function parameters" do
    ast =
      quote do
        defmodule Sample do
          def value(input, fallback \\ input), do: fallback
        end
      end

    assert_raise Error, ~r/default_arg_param_reference for value\/2/, fn ->
      DefaultArgExpand.expand(ast)
    end
  end

  test "rejects generated arity collisions" do
    ast =
      quote do
        defmodule Sample do
          def value(input \\ 1), do: input
          def value, do: 2
        end
      end

    assert_raise Error, ~r/default_arity_collision for value\/0/, fn ->
      DefaultArgExpand.expand(ast)
    end
  end

  defp fixture(module) do
    quote do
      defmodule unquote(module) do
        def value(
              a \\ (
                send(self(), :a)
                1
              ),
              b,
              c \\ (
                send(self(), :c)
                3
              )
            ),
            do: {a, b, c}
      end
    end
  end

  defp invocation_trace(module) do
    first = module.value(:middle)
    first_messages = receive_messages([])
    second = module.value(:x, :middle)
    second_messages = receive_messages([])
    [{first, first_messages}, {second, second_messages}]
  end

  defp receive_messages(messages) do
    receive do
      message when message in [:a, :c] -> receive_messages(messages ++ [message])
    after
      0 -> messages
    end
  end
end
