defmodule Batata.Native.Enumerable do
  @moduledoc """
  Compile-time Enumerable protocol registry (native callback registration,
  expandable route — tsai/beaver#30).

  The Zig runtime dispatches enumerable operations by term tag; this module
  records which consolidated `Enumerable` implementations map to native
  (runtime-tag) dispatch and which are external (requiring the BEAM or
  explicit rejection). It mirrors expandable's
  `runtime_enumerable_consolidation` table at compile time.
  """

  # Batata's runtime dispatches by term tag for these built-in enumerables
  # (the Zig term runtime implements count/reduce for them). Range is a BEAM
  # Enumerable impl and also a native runtime path; Tuple/Binary are batata
  # slice extensions (not BEAM Enumerable impls).
  @internal_impls [List, Map, Range]
  @runtime_tags [:list, :map, :tuple, :binary, :range]

  @doc "Consolidated Enumerable implementations, or [] when unconsolidated."
  @spec impls() :: [module()]
  def impls do
    case Enumerable.__protocol__(:impls) do
      {:consolidated, impls} -> impls
      :not_consolidated -> []
    end
  end

  @doc "Whether the impl has a native (term-tag) dispatch path in the runtime."
  @spec internal?(module()) :: boolean()
  def internal?(impl), do: impl in @internal_impls

  @doc "Consolidated impls without a native dispatch path (external/BEAM-side)."
  @spec external() :: [module()]
  def external do
    impls() |> Enum.reject(&internal?/1)
  end

  @doc """
  The native dispatch registry: tag -> implementation metadata, mirroring the
  runtime's term-tag dispatch for count/reduce.
  """
  @spec registry() :: [map()]
  def registry do
    [
      %{impl: List, tag: :list, count: :native, reduce: :native},
      %{impl: Map, tag: :map, count: :native, reduce: :native},
      %{impl: Range, tag: :range, count: :native, reduce: :native},
      %{impl: Tuple, tag: :tuple, count: :native, reduce: :native},
      %{impl: Binary, tag: :binary, count: :native, reduce: :native}
    ]
  end

  @doc "All tags the runtime dispatches on (internal + batata extensions)."
  @spec runtime_tags() :: [atom()]
  def runtime_tags, do: @runtime_tags
end
