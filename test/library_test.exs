defmodule Batata.LibraryTest do
  use Batata.Case, async: true

  alias Batata.{Export, Library}
  alias Batata.Test.Subprocess
  alias Beaver.MLIR.CompilationRuntime

  @tag :tmp_dir
  test "builds a multi-export shared library without a driver or term runtime", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Library.build(
        """
        defmodule ScalarKernel do
          def add(left, right), do: left + right
          def sub(left, right), do: left - right
        end
        """,
        tmp_dir,
        ctx,
        library_name: "batata_scalar_kernel",
        exports: [
          %{function: :add, arity: 2, symbol: "batata_scalar_add"},
          %{function: :sub, arity: 2, symbol: "batata_scalar_sub"}
        ],
        dependency_pins: %{
          "beaver" => "d972dc93e6245fc4f68e8b3cc848db2e258e92ca",
          "llvm" => CompilationRuntime.llvm_revision()
        }
      )

    assert File.regular?(output.object)
    assert File.regular?(output.library)
    refute File.exists?(Path.join(tmp_dir, "driver.c"))
    refute Enum.any?(File.ls!(tmp_dir), &String.contains?(&1, "term_runtime"))

    %{bundle: bundle, artifact_index: index} = Export.read(tmp_dir)
    assert bundle["entry"] == nil
    assert bundle["artifact_kind"] == "shared-library"
    assert bundle["compiler_abi"] == %{"name" => "batata-scalar-c", "version" => 1}
    assert bundle["dependency_pins"]["beaver"] =~ ~r/^[0-9a-f]{40}$/

    assert bundle["exports"] == [
             %{"function" => "ScalarKernel.add/2", "symbol" => "batata_scalar_add"},
             %{"function" => "ScalarKernel.sub/2", "symbol" => "batata_scalar_sub"}
           ]

    paths = Enum.map(index["files"], & &1["path"])
    assert Path.basename(output.library) in paths
    assert "batata-library.o" in paths

    runner_source = Path.join(tmp_dir, "runner.c")
    runner = Path.join(tmp_dir, "run-library")

    File.write!(runner_source, """
    #include <stdint.h>
    extern int64_t batata_scalar_add(int64_t, int64_t);
    extern int64_t batata_scalar_sub(int64_t, int64_t);
    int main(void) {
      return batata_scalar_add(20, 22) == 42 && batata_scalar_sub(20, 7) == 13 ? 0 : 1;
    }
    """)

    {_, 0} =
      System.cmd("zig", ["cc", runner_source, output.library, "-o", runner],
        stderr_to_stdout: true
      )

    assert {"", 0} = Subprocess.cmd(runner, timeout: 15_000)
  end

  @tag :tmp_dir
  test "fails closed for implicit entry points and term-runtime operations", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    assert_raise ArgumentError, ~r/must not define an implicit main/, fn ->
      Library.build("defmodule Bad do def main(), do: 1 end", tmp_dir, ctx, base_options())
    end

    assert_raise ArgumentError, ~r/cannot link the Batata term runtime/, fn ->
      Library.build(
        "defmodule Bad do def identity(value), do: [value] end",
        tmp_dir,
        ctx,
        Keyword.put(base_options(), :exports, [
          %{function: :identity, arity: 1, symbol: "identity"}
        ])
      )
    end
  end

  defp base_options do
    [
      library_name: "bad",
      exports: [%{function: :unused, arity: 0, symbol: "unused"}],
      dependency_pins: %{"beaver" => "fixture"}
    ]
  end
end
