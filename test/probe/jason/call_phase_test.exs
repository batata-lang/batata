defmodule Batata.Probe.Jason.CallPhaseTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.AliasExpand
  alias Batata.Probe.Jason.CallPhase

  test "classifies module, macro, runtime, quote, and unquote call phases" do
    ast =
      """
      defmodule Fixture do
        alias Full.Provider, as: Provider

        Provider.module_build()

        def runtime(value), do: Provider.runtime(value)

        defmacro generated(value) do
          prepared = Provider.prepare(value)

          quote do
            Provider.generated_runtime(unquote(Provider.inject(prepared)))
          end
        end
      end
      """
      |> Code.string_to_quoted!()
      |> AliasExpand.expand()

    assert ast |> CallPhase.collect() |> sorted() == [
             {"Full.Provider", {:generated_runtime, 1}, :runtime},
             {"Full.Provider", {:inject, 1}, :compile_time},
             {"Full.Provider", {:module_build, 0}, :compile_time},
             {"Full.Provider", {:prepare, 1}, :compile_time},
             {"Full.Provider", {:runtime, 1}, :runtime}
           ]
  end

  test "recurses through protocol implementations without flattening definition phases" do
    ast =
      Code.string_to_quoted!("""
      defimpl Fixture.Protocol, for: Any do
        defmacro deriving(value), do: Fixture.Provider.prepare(value)
        def encode(value), do: Fixture.Provider.encode(value)
      end
      """)

    assert ast |> CallPhase.collect() |> sorted() == [
             {"Fixture.Provider", {:encode, 1}, :runtime},
             {"Fixture.Provider", {:prepare, 1}, :compile_time}
           ]
  end

  test "classifies every form in a multi-form source root independently" do
    ast =
      Code.string_to_quoted!("""
      defmodule Fixture.Provider do
        def runtime(value), do: Fixture.Target.runtime(value)
      end

      defimpl Fixture.Protocol, for: Any do
        def encode(value), do: Fixture.Target.protocol_runtime(value)
      end

      Fixture.Target.module_build()
      """)

    assert ast |> CallPhase.collect() |> sorted() == [
             {"Fixture.Target", {:module_build, 0}, :compile_time},
             {"Fixture.Target", {:protocol_runtime, 1}, :runtime},
             {"Fixture.Target", {:runtime, 1}, :runtime}
           ]
  end

  test "selects only signatures with compile-time incoming edges and no runtime edge" do
    calls =
      MapSet.new([
        {"Provider", {:compile_only, 1}, :compile_time},
        {"Provider", {:shared, 1}, :compile_time},
        {"Provider", {:shared, 1}, :runtime},
        {"Provider", {:runtime_only, 1}, :runtime},
        {"Other", {:build, 0}, :compile_time}
      ])

    assert CallPhase.compile_time_only(calls) == %{
             "Other" => MapSet.new(build: 0),
             "Provider" => MapSet.new(compile_only: 1)
           }
  end

  defp sorted(calls), do: Enum.sort(calls)
end
