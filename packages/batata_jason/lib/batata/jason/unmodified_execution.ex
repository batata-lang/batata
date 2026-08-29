defmodule Batata.Jason.UnmodifiedExecution do
  @moduledoc """
  Executes a bounded semantic sample through an unmodified Jason checkout.

  The Jason sources are normalized as one qualified compilation unit. A small
  probe-owned wrapper supplies the sole JIT entry point, so every case shares
  one frontend, lowering, and execution-engine lifetime. The expected value is
  produced by compiling the same unmodified checkout in an isolated BEAM
  subprocess.
  """

  alias Batata.CompilationUnit
  alias Batata.Frontend
  alias Batata.Probe.CorpusRuntimeSlice
  alias Beaver.MLIR

  @case_count 18
  @wrapper_module Batata.Jason.UnmodifiedOracle
  @wrapper_source ~S'''
  defmodule Batata.Jason.DerivedFixture do
    @derive {Jason.Encoder, only: [:visible]}
    defstruct [:visible, :hidden]
  end

  defmodule Batata.Jason.UnknownFixture do
    defstruct [:value]
  end

  defmodule Batata.Jason.UnmodifiedOracle do
    def main() do
      {
        Jason.decode!("null"),
        Jason.decode!("true"),
        Jason.decode!("-42"),
        Jason.decode!("1.5"),
        Jason.decode!("\"snowman: \\u2603\""),
        Jason.decode!("[1,false,null,\"x\"]"),
        Jason.decode!("{\"x\":[1,true,null]}"),
        Jason.encode!(nil),
        Jason.encode!(true),
        Jason.encode!(-42),
        Jason.encode!(1.5),
        Jason.encode!("snowman: ☃"),
        Jason.encode!([1, false, nil, "x"]),
        Jason.encode!(%{"x" => [1, true, nil]}),
        Jason.Encoder.encode(7, nil),
        Jason.encode!(%Batata.Jason.DerivedFixture{visible: 1, hidden: 2}),
        Jason.Encoder.encode(~D[2026-08-29], nil),
        decode_error(),
        unknown_struct_error()
      }
    end

    defp decode_error() do
      try do
        Jason.decode!("invalid")
      rescue
        error in Jason.DecodeError -> {error.__struct__, Exception.message(error)}
      end
    end

    defp unknown_struct_error() do
      try do
        Jason.encode!(%Batata.Jason.UnknownFixture{value: 1})
      rescue
        error in Protocol.UndefinedError -> {error.__struct__, Exception.message(error)}
      end
    end
  end
  '''

  @doc "Runs the pinned source on BEAM and Batata, failing on any semantic difference."
  @spec run!(Path.t()) :: map()
  def run!(source) do
    files = source_files(source)
    expected = beam_oracle!(files)
    actual = batata_oracle!(source, files)

    if actual != expected do
      raise RuntimeError,
            "unmodified Jason semantic mismatch: " <>
              "BEAM=#{fingerprint(expected)} Batata=#{fingerprint(actual)}"
    end

    %{
      "status" => "pass",
      "mode" => "qualified_multi_module_jit_vs_isolated_beam",
      "entry" => "#{inspect(@wrapper_module)}.main/0",
      "cases" => @case_count,
      "source_files" => length(files),
      "oracle_fingerprint" => fingerprint(expected),
      "actual_fingerprint" => fingerprint(actual)
    }
  end

  defp batata_oracle!(source, files) do
    sources = Enum.map(files, &File.read!/1)
    modules = Frontend.from_sources(sources ++ [@wrapper_source])
    runtime_modules = CorpusRuntimeSlice.slice(source, modules).modules
    unit = CompilationUnit.build(runtime_modules, entry: {@wrapper_module, :main, 0})
    ctx = MLIR.Context.create()

    try do
      Batata.execute(unit, ctx, workers: 1)
    after
      MLIR.Context.destroy(ctx)
    end
  end

  defp beam_oracle!(files) do
    root =
      Path.join(System.tmp_dir!(), "batata-jason-oracle-#{System.unique_integer([:positive])}")

    ebin = Path.join(root, "ebin")
    wrapper = Path.join(root, "oracle.ex")
    File.mkdir_p!(ebin)

    try do
      File.write!(wrapper, @wrapper_source)

      {_output, 0} =
        System.cmd(elixir_executable!("elixirc"), ["-o", ebin | files ++ [wrapper]],
          stderr_to_stdout: true
        )

      expression =
        "Batata.Jason.UnmodifiedOracle.main()" <>
          " |> :erlang.term_to_binary() |> Base.encode64() |> IO.write()"

      {encoded, 0} =
        System.cmd(elixir_executable!("elixir"), ["-pa", ebin, "-e", expression],
          stderr_to_stdout: true
        )

      encoded
      |> Base.decode64!()
      |> :erlang.binary_to_term([:safe])
    after
      File.rm_rf!(root)
    end
  end

  defp elixir_executable!(name) do
    System.find_executable(name) || raise "#{name} executable is required for the BEAM oracle"
  end

  defp source_files(source) do
    root = if File.dir?(Path.join(source, "lib")), do: Path.join(source, "lib"), else: source
    root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  defp fingerprint(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
