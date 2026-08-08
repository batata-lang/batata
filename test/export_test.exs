defmodule Batata.ExportTest do
  use Batata.Case, async: true

  alias Batata
  alias Batata.{Export, Upgrade.Diff}

  @tag :tmp_dir
  test "build emits an export bundle with metadata", %{ctx: ctx, tmp_dir: tmp_dir} do
    output =
      Batata.build(
        """
        defmodule Math do
          def main() do
            1 + 2
          end
        end
        """,
        tmp_dir,
        ctx
      )

    assert File.exists?(output.bundle)
    assert File.exists?(output.artifact_index)
    assert File.exists?(output.manifest)

    %{bundle: bundle, artifact_index: index, manifest: manifest} = Export.read(tmp_dir)

    assert bundle["module"] == "Math"
    assert bundle["entry"] == "batata_main"
    assert bundle["source_digest"] |> byte_size() == 64
    assert bundle["artifact_digest"] |> byte_size() == 64
    assert bundle["runtime_version"] |> byte_size() == 64
    assert manifest["compiler"] == "batata"

    paths = index["files"] |> Enum.map(& &1["path"])
    assert "libElixir.Math.a" in paths
    assert "batata.o" in paths
    assert "driver.c" in paths
  end

  @tag :tmp_dir
  test "diff reports no change for an identical rebuild", %{ctx: ctx, tmp_dir: tmp_dir} do
    source = """
    defmodule Math do
      def main() do
        1 + 2
      end
    end
    """

    old_dir = Path.join(tmp_dir, "old")
    new_dir = Path.join(tmp_dir, "new")
    File.mkdir_p!(old_dir)
    File.mkdir_p!(new_dir)

    Batata.build(source, old_dir, ctx)
    Batata.build(source, new_dir, ctx)

    summary = Diff.compare(old_dir, new_dir)

    refute summary.artifacts_changed
    refute summary.migration_required
    assert summary.file_additions == 0
    assert summary.file_removals == 0
    assert summary.file_changes == 0
  end

  @tag :tmp_dir
  test "diff flags changed artifacts when the source changes", %{ctx: ctx, tmp_dir: tmp_dir} do
    old_dir = Path.join(tmp_dir, "old")
    new_dir = Path.join(tmp_dir, "new")
    File.mkdir_p!(old_dir)
    File.mkdir_p!(new_dir)

    Batata.build(
      """
      defmodule Math do
        def main() do
          1 + 2
        end
      end
      """,
      old_dir,
      ctx
    )

    Batata.build(
      """
      defmodule Math do
        def main() do
          1 + 2 + 3
        end
      end
      """,
      new_dir,
      ctx
    )

    summary = Diff.compare(old_dir, new_dir)

    assert summary.artifacts_changed
    assert summary.migration_required

    changed = Enum.filter(summary.file_surface, &(&1["status"] == "changed"))
    assert Enum.any?(changed, &String.ends_with?(&1["path"], ".a"))
  end

  @tag :tmp_dir
  test "diff raises without an export bundle", %{ctx: ctx, tmp_dir: tmp_dir} do
    empty = Path.join(tmp_dir, "empty")
    File.mkdir_p!(empty)

    assert_raise ArgumentError, ~r/no export bundle/, fn ->
      Diff.compare(empty, empty)
    end
  end
end
