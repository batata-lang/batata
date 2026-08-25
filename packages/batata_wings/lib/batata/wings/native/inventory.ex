defmodule Batata.Wings.Native.Inventory do
  @moduledoc """
  Produces a path-preserving inventory of Wings source considered for Batata AOT.

  A source is marked compilable only after `Batata.compile/3` has produced and
  verified an MLIR module. Parser success, a generated wrapper symbol, or a
  loadable host BEAM does not count as native eligibility.
  """

  alias Batata.Wings.CanonicalJSON
  alias Beaver.MLIR

  @package_root Path.expand("../../../..", __DIR__)

  @sources [
    {Batata.Wings.Vec3, "lib/batata/wings/vec3.ex"},
    {Batata.Wings.Mesh, "lib/batata/wings/mesh.ex"},
    {Batata.Wings.Topology, "lib/batata/wings/topology.ex"},
    {Batata.Wings.Topology.Build, "lib/batata/wings/topology/build.ex"},
    {Batata.Wings.Selection, "lib/batata/wings/selection.ex"},
    {Batata.Wings.Geometry, "lib/batata/wings/geometry.ex"},
    {Batata.Wings.Operation.Move, "lib/batata/wings/operation/move.ex"},
    {Batata.Wings.EditorState, "lib/batata/wings/editor_state.ex"},
    {Batata.Wings.EditCommand, "lib/batata/wings/edit_command.ex"},
    {Batata.Wings.Editor, "lib/batata/wings/editor.ex"},
    {Batata.Wings.Native.Kernel, "lib/batata/wings/native/kernel.ex"}
  ]

  @schema 1

  @doc "Returns the closed source set without claiming native compilability."
  @spec source_inventory(Path.t()) :: map()
  def source_inventory(package_root \\ @package_root) do
    entries = Enum.map(@sources, &source_entry(&1, package_root))

    %{
      "entries" => entries,
      "schema_version" => @schema,
      "source_set_sha256" => digest(CanonicalJSON.encode!(entries))
    }
  end

  @doc "Runs a real Batata compile probe for every declared source."
  @spec probe(MLIR.Context.t(), Path.t(), keyword()) :: map()
  def probe(ctx, package_root \\ @package_root, options \\ []) do
    inventory = source_inventory(package_root)

    entries =
      Enum.map(inventory["entries"], fn entry ->
        relative_path = String.replace_prefix(entry["source"], "packages/batata_wings/", "")
        source = package_root |> Path.join(relative_path) |> File.read!()
        Map.merge(entry, compile_entry(source, ctx, options))
      end)

    Map.merge(inventory, %{
      "entries" => entries,
      "probe_sha256" => digest(CanonicalJSON.encode!(entries))
    })
  end

  @doc "Writes a canonical JSON compile-probe receipt."
  @spec write!(Path.t(), MLIR.Context.t(), Path.t(), keyword()) :: Path.t()
  def write!(path, ctx, package_root \\ @package_root, options \\ []) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, probe(ctx, package_root, options) |> CanonicalJSON.encode!())
    path
  end

  defp source_entry({module, relative_path}, package_root) do
    source_path = Path.join(package_root, relative_path)
    source = File.read!(source_path)

    %{
      "functions" => functions(source),
      "module" => inspect(module),
      "source" => "packages/batata_wings/#{relative_path}",
      "source_sha256" => digest(source)
    }
  end

  defp compile_entry(source, ctx, options) do
    module = Batata.compile(source, ctx, options)
    MLIR.Module.destroy(module)

    %{"blockers" => [], "status" => "compilable"}
  rescue
    error ->
      %{
        "blockers" => [
          %{
            "code" => "E_WINGS_NATIVE_COMPILE_BLOCKED",
            "exception" => inspect(error.__struct__),
            "feature" => Exception.message(error)
          }
        ],
        "status" => "blocked"
      }
  end

  defp functions(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {kind, _metadata, [{name, _, arguments} | _]} = node, entries
      when kind in [:def, :defp] and is_atom(name) ->
        arity = if is_list(arguments), do: length(arguments), else: 0

        {node,
         [
           %{"arity" => arity, "name" => Atom.to_string(name), "visibility" => visibility(kind)}
           | entries
         ]}

      node, entries ->
        {node, entries}
    end)
    |> elem(1)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["name"], &1["arity"], &1["visibility"]})
  end

  defp visibility(:def), do: "public"
  defp visibility(:defp), do: "private"

  defp digest(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
