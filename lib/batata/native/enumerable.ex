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

  @doc """
  Compile-time plan for an impl's count/reduce: `:runtime_tag` (the Zig
  runtime implements it by term tag) or `:unsupported` with a reason (the
  impl's Elixir implementation is outside the slice, so a native count/reduce
  cannot be compiled yet — MISSING_IMPL discipline, never silent).
  """
  @spec compile_plan(module()) :: %{
          count: :runtime_tag | :unsupported,
          reduce: :runtime_tag | :unsupported,
          reason: String.t() | nil
        }
  def compile_plan(impl) do
    if internal?(impl) do
      %{count: :runtime_tag, reduce: :runtime_tag, reason: nil}
    else
      %{
        count: :unsupported,
        reduce: :unsupported,
        reason:
          "#{inspect(impl)} Enumerable is outside the slice; a native count/reduce requires a Provider plan or BEAM"
      }
    end
  end

  @doc """
  Plans for all consolidated impls, for diagnostics and dispatch-table
  generation.
  """
  @spec plans() :: [{module(), map()}]
  def plans do
    impls() |> Enum.map(&{&1, compile_plan(&1)})
  end

  @doc """
  Registers a project-provided native count/reduce for an external impl,
  returning the registration descriptor consumed by the runtime callback
  table (`ex.term.register_callback`). Returns nil when the impl is already
  internal or no plan is provided.
  """
  @spec register_native(module(), %{count: integer(), reduce: integer()}) ::
          {:ok, [{integer(), atom()}]} | nil
  def register_native(impl, %{count: count_id, reduce: reduce_id}) do
    if internal?(impl) do
      nil
    else
      {:ok, [{count_id, :count}, {reduce_id, :reduce}]}
    end
  end
end
