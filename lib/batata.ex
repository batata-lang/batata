defmodule Batata do
  @moduledoc """
  An Elixir-to-native compiler built on [Beaver](https://github.com/beaver-lodge/beaver)
  and the Slang-defined `ex` dialect.

  The frontend boundary lowers an expanded module snapshot to `ex` IR, then
  information-preserving IR-to-IR transforms run (`Batata.Transform`, e.g.
  scalar call inlining), then `ex` lowers to `func`/`arith`/`scf`/`cf` and
  finally to LLVM via `Beaver.MLIR.Conversion.Plan`. Both JIT (`execute/2`)
  and AOT (`build/3`) execution are supported.
  """

  alias Batata.Lower
  alias Beaver.MLIR
  alias Beaver.Native
  alias Beaver.Native.I64

  @doc """
  Parses and lowers Elixir source into a verified `builtin.module` of `ex`
  operations.
  """
  @spec compile(String.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def compile(source, ctx, opts \\ []) do
    validate_reduction_budget!(opts[:reduction_budget])

    module =
      source
      |> Batata.Frontend.from_source()
      |> Batata.Lift.module_to_ir(
        ctx: ctx,
        reduction_budget: opts[:reduction_budget],
        reduction_batching: opts[:reduction_batching]
      )
      |> Beaver.Deferred.create(ctx)

    module
    |> Batata.Transform.run!([
      Batata.Transform.InlineScalarCalls,
      Batata.Transform.ExpandCase
    ])
    |> MLIR.verify!()
  end

  # The reduction budget drives the batched tick (`ex.reduction_tick(budget)`
  # once per budget iterations, #41): it must be a positive integer when set.
  defp validate_reduction_budget!(nil), do: :ok

  defp validate_reduction_budget!(budget) when is_integer(budget) and budget > 0, do: :ok

  defp validate_reduction_budget!(budget) do
    raise ArgumentError,
          "reduction_budget must be a positive integer or nil, got: #{inspect(budget)}"
  end

  @doc """
  Parses Elixir source and lowers it all the way to LLVM dialect IR.
  """
  @spec to_llvm(String.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def to_llvm(source, ctx) do
    source
    |> compile(ctx)
    |> Lower.to_llvm(ctx)
    |> MLIR.verify!()
  end

  @doc """
  Parses Elixir source, lowers it to LLVM and executes `main` through the
  MLIR JIT, returning its value.

  The JIT engine and module are destroyed before returning.
  """
  @spec execute(String.t(), MLIR.Context.t()) :: term()
  def execute(source, ctx, opts \\ []) do
    module =
      source
      |> compile(ctx, opts)
      |> Lower.to_llvm(ctx, c_interface: true)
      |> MLIR.verify!()

    jit = MLIR.ExecutionEngine.create!(module, execution_engine_opts(module))

    try do
      return = I64.make(0)
      MLIR.ExecutionEngine.invoke!(jit, "main", [], return)
      Native.to_term(return)
    after
      MLIR.ExecutionEngine.destroy(jit)
      MLIR.Module.destroy(module)
    end
  end

  # Term ops lower to `ex.term.*` calls; when they are present the JIT must be
  # able to resolve them, so the Zig term runtime shared library is attached.
  defp execution_engine_opts(module) do
    if MLIR.to_string(module) =~ "ex.term." do
      [shared_lib_paths: [Batata.TermRuntime.ensure_built!()]]
    else
      []
    end
  end

  @doc """
  Compiles Elixir source to a static library and a C driver.

  The entry function `main` is renamed to `batata_main` in the generated
  object so the driver can call it without colliding with the C entry point.
  Returns a map with the archive, driver and object paths.

  Link the driver against the archive and run it:

      cc driver.c libMath.a -o run_math
  """
  @spec build(String.t(), Path.t(), MLIR.Context.t()) :: %{
          archive: Path.t(),
          driver: Path.t(),
          object: Path.t(),
          runtime_lib: Path.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          manifest: Path.t()
        }
  def build(source, output_dir, ctx) do
    snapshot =
      source
      |> Batata.Frontend.from_source()
      |> rename_entry(:batata_main)

    module =
      snapshot
      |> Batata.Lift.module_to_ir(ctx: ctx)
      |> Beaver.Deferred.create(ctx)
      |> Batata.Transform.run!([
        Batata.Transform.InlineScalarCalls,
        Batata.Transform.ExpandCase
      ])
      |> MLIR.verify!()
      |> Batata.Lower.to_llvm(ctx)
      |> MLIR.verify!()

    File.mkdir_p!(output_dir)

    object_path = Path.join(output_dir, "batata.o")
    archive_path = Path.join(output_dir, "lib#{snapshot.name}.a")
    driver_path = Path.join(output_dir, "driver.c")
    runtime_lib = Batata.TermRuntime.ensure_static_built!()
    runtime_lib_copy = Path.join(output_dir, Path.basename(runtime_lib))
    File.cp!(runtime_lib, runtime_lib_copy)

    jit =
      MLIR.ExecutionEngine.create!(module, [object_dump: true] ++ execution_engine_opts(module))

    try do
      MLIR.ExecutionEngine.emit_object!(jit, object_path)
    after
      MLIR.ExecutionEngine.destroy(jit)
    end

    archive!(archive_path, object_path)
    File.write!(driver_path, driver_source())

    metadata =
      Batata.Export.write!(output_dir, snapshot.name,
        source: source,
        artifact_paths: [archive_path, object_path, driver_path, runtime_lib_copy],
        definitions: snapshot.definitions,
        entry_name: :main
      )

    %{
      archive: archive_path,
      driver: driver_path,
      object: object_path,
      runtime_lib: runtime_lib_copy,
      bundle: metadata.bundle,
      artifact_index: metadata.artifact_index,
      manifest: metadata.manifest
    }
  end

  defp rename_entry(%Batata.Frontend.Module{} = snapshot, entry) do
    %{
      snapshot
      | definitions:
          Enum.map(snapshot.definitions, fn
            %Batata.Frontend.Definition{name: :main} = definition ->
              %{definition | name: entry}

            definition ->
              definition
          end)
    }
  end

  defp archive!(archive_path, object_path) do
    ar = System.find_executable("ar") || raise "ar not found on PATH"
    {_output, 0} = System.cmd(ar, ["rcs", archive_path, object_path], stderr_to_stdout: true)
    archive_path
  end

  defp driver_source do
    """
    #include <stdint.h>
    #include <stdio.h>

    extern int64_t batata_main(void);

    int main(void) {
      printf("%lld\\n", (long long)batata_main());
      return 0;
    }
    """
  end
end
