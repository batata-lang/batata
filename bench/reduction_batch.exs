# Benchmark for the batched reduction tick (#41).
#
# Each scenario compiles once, creates the JIT once, warms up, then times
# only the invocations (median of N runs). `yield_count` is read through a
# tiny NIF linked against the term runtime, so the delta per invocation is
# reported without carrying JIT build time or stale global counters.
#
# Run: mix run bench/reduction_batch.exs

defmodule ReductionBench.Nif do
  def load(path) do
    case :erlang.load_nif(String.to_charlist(path), 0) do
      :ok -> :ok
      {:error, reason} -> raise "NIF load failed: #{inspect(reason)}"
    end
  end

  def yield_count, do: :erlang.nif_error(:nif_not_loaded)
end

defmodule ReductionBench do
  alias Beaver.MLIR

  def run do
    build_nif!()
    ctx = MLIR.Context.create()

    IO.puts("== scenario A: Enum.reduce(1..1_000_000, 0, +) (runtime reduce, no tick) ==")

    bench_scenario(
      ctx,
      """
      defmodule M do
        def main() do
          Enum.reduce(1..1000000, 0, fn x, a -> x + a end)
        end
      end
      """,
      "range reduce"
    )

    data = Path.join(System.tmp_dir!(), "batata_bench_data.bin")
    File.write!(data, :binary.copy(<<65>>, 100_000))

    IO.puts("== scenario B: binary scanner over 100_000 bytes (cursor loop, real tick) ==")

    bench_scenario(
      ctx,
      """
      defmodule M do
        def count(<<_::8, t::binary>>), do: 1 + count(t)
        def count(<<>>), do: 0

        def main() do
          count(File.read!(#{inspect(data)}))
        end
      end
      """,
      "binary scanner"
    )

    MLIR.Context.destroy(ctx)
  end

  defp bench_scenario(ctx, source, label) do
    for {mode, opts} <- mode_matrix(label) do
      {median_us, yield_delta} = time_invocations(ctx, source, opts)
      IO.puts("  #{String.pad_trailing(label <> " / " <> mode, 50)} " <>
                "median #{median_us}us  yield_delta #{yield_delta}")
    end

    IO.puts("")
  end

  # With a budget smaller than the loop length the slice boundaries (and
  # yields) must match between modes; with a budget larger than the loop the
  # per-iteration mode still performs one clock_tick call per iteration while
  # the batched mode performs zero, isolating the tick-call overhead.
  defp mode_matrix("binary scanner") do
    [
      {"no budget", []},
      {"per-iteration budget 10_000 (yields)", [reduction_budget: 10_000, reduction_batching: false]},
      {"batched budget 10_000 (yields)", [reduction_budget: 10_000]},
      {"per-iteration budget 1_000_000 (tick calls)", [reduction_budget: 1_000_000, reduction_batching: false]},
      {"batched budget 1_000_000 (tick calls)", [reduction_budget: 1_000_000]}
    ]
  end

  defp mode_matrix(_label) do
    [
      {"no budget", []},
      {"per-iteration", [reduction_budget: 10_000, reduction_batching: false]},
      {"batched", [reduction_budget: 10_000]}
    ]
  end

  defp time_invocations(ctx, source, opts) do
    module =
      source
      |> Batata.compile(ctx, opts)
      |> Batata.Lower.to_llvm(ctx, c_interface: true)

    jit =
      MLIR.ExecutionEngine.create!(
        module,
        [shared_lib_paths: [Batata.TermRuntime.ensure_built!()]]
      )

    try do
      # warmup: 3 invocations (JIT materialization and page faults settle)
      for _ <- 1..3 do
        invoke(jit)
      end

      before = ReductionBench.Nif.yield_count()

      results =
        for _ <- 1..7 do
          start = :erlang.monotonic_time(:microsecond)
          result = invoke(jit)
          :erlang.monotonic_time(:microsecond) - start
          result
        end

      if Enum.uniq(results) != [results |> hd()] do
        raise "benchmark results not stable: #{inspect(results)}"
      end

      times =
        for _ <- 1..7 do
        start = :erlang.monotonic_time(:microsecond)
        invoke(jit)
        :erlang.monotonic_time(:microsecond) - start
      end

      after_count = ReductionBench.Nif.yield_count()

      {median(times), after_count - before}
    after
      MLIR.ExecutionEngine.destroy(jit)
      MLIR.Module.destroy(module)
    end
  end

  defp invoke(jit) do
    return = Beaver.Native.I64.make(0)
    MLIR.ExecutionEngine.invoke!(jit, "main", [], return)
    Beaver.Native.to_term(return)
  end

  defp median(times), do: times |> Enum.sort() |> then(fn t -> Enum.at(t, div(length(t), 2)) end)

  defp build_nif! do
    root = :code.root_dir()

    erts_include =
      case Path.wildcard(Path.join(root, "erts-*/include")) do
        [dir | _] -> dir
        [] -> Path.join(:code.lib_dir(:erts), "include")
      end

    runtime = Batata.TermRuntime.ensure_built!()
    dir = Path.join(System.tmp_dir!(), "batata_bench_nif")
    File.mkdir_p!(dir)
    c_src = Path.join(dir, "yield_count.c")
    so = Path.join(dir, "yield_count.so")

    File.write!(c_src, """
    #include <erl_nif.h>
    extern long long ex_term_yield_count(void);
    static ERL_NIF_TERM nif_yield_count(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
      (void)env; (void)argc; (void)argv;
      return enif_make_int64(env, ex_term_yield_count());
    }
    static ErlNifFunc nif_funcs[] = {{"yield_count", 0, nif_yield_count}};
    ERL_NIF_INIT(Elixir.ReductionBench.Nif, nif_funcs, NULL, NULL, NULL, NULL)
    """)

    {_, 0} =
      System.cmd("cc", [
        "-shared",
        "-fPIC",
        "-I",
        erts_include,
        c_src,
        "-L",
        Path.dirname(runtime),
        "-lterm_runtime",
        "-Wl,-rpath,#{Path.dirname(runtime)}",
        "-o",
        so
      ])

    ReductionBench.Nif.load(Path.rootname(so))
    :ok
  end
end

ReductionBench.run()
