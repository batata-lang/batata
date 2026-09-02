defmodule Batata.Decimal.UnmodifiedExecution do
  @moduledoc """
  Executes a bounded finite-number sample through an unmodified Decimal checkout.

  The Decimal sources are normalized as one qualified compilation unit. A
  probe-owned wrapper supplies the sole JIT entry point, and an isolated BEAM
  subprocess evaluates the same pinned files and wrapper as the oracle.
  """

  alias Batata.CompilationUnit
  alias Batata.Frontend
  alias Batata.Probe.CorpusRuntimeSlice
  alias Beaver.MLIR

  @case_count 15
  @wrapper_module Batata.Decimal.UnmodifiedOracle
  @wrapper_source ~S'''
  defmodule Batata.Decimal.UnmodifiedOracle do
    def main() do
      {
        Decimal.new(0),
        Decimal.new(-42),
        Decimal.new("12.30"),
        Decimal.add("1.2", "3.4"),
        Decimal.sub("5.5", "2.25"),
        Decimal.mult("1.25", "4"),
        Decimal.compare("1.20", "1.3"),
        Decimal.compare("1.20", "1.2"),
        if(Decimal.equal?("10.0", "10"), do: true, else: false),
        if(Decimal.equal?("10.1", "10"), do: true, else: false),
        Decimal.normalize(Decimal.new("12.300")),
        Decimal.to_string(Decimal.new("12.300"), :normal),
        Decimal.to_string(Decimal.new("0.00123"), :scientific),
        Decimal.to_string(Decimal.new("-12.30"), :raw),
        Decimal.parse("12.30")
      }
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
            "unmodified Decimal semantic mismatch: " <>
              "BEAM=#{fingerprint(expected)} Batata=#{fingerprint(actual)} " <>
              "differences=#{inspect(semantic_differences(expected, actual), limit: :infinity)}"
    end

    %{
      "status" => "pass",
      "mode" => "qualified_multi_module_jit_vs_isolated_beam",
      "entry" => "#{inspect(@wrapper_module)}.main/0",
      "cases" => @case_count,
      "source_files" => length(files),
      "oracle_fingerprint" => fingerprint(expected),
      "actual_fingerprint" => fingerprint(actual),
      "scope" => "finite immediate-range Decimal values"
    }
  end

  defp semantic_differences(expected, actual) when is_tuple(expected) and is_tuple(actual) do
    expected
    |> Tuple.to_list()
    |> Enum.zip(Tuple.to_list(actual))
    |> Enum.with_index(1)
    |> Enum.flat_map(fn
      {{same, same}, _index} -> []
      {{beam, batata}, index} -> [%{case: index, beam: beam, batata: batata}]
    end)
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
      Path.join(System.tmp_dir!(), "batata-decimal-oracle-#{System.unique_integer([:positive])}")

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
        "Batata.Decimal.UnmodifiedOracle.main()" <>
          " |> :erlang.term_to_binary() |> Base.encode64() |> IO.write()"

      {encoded, 0} =
        System.cmd(elixir_executable!("elixir"), ["-pa", ebin, "-e", expression],
          stderr_to_stdout: true
        )

      encoded
      |> Base.decode64!()
      |> :erlang.binary_to_term()
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
