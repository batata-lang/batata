defmodule Batata.Stdlib.Kernel do
  @moduledoc """
  Kernel-domain declarations. Entries mirror `Kernel`/`:erlang` BIFs that the
  term slice can replace through the Zig runtime.
  """

  @class_map %{
    {Kernel, :length, 1} => :native_term,
    {Kernel, :hd, 1} => :native_term,
    {Kernel, :tl, 1} => :native_term,
    {Kernel, :tuple_size, 1} => :native_term,
    {Kernel, :elem, 2} => :native_term,
    {Kernel, :byte_size, 1} => :native_term,
    {Kernel, :map_size, 1} => :native_term,
    {Kernel, :list_to_binary, 1} => :native_term,
    {Kernel, :inspect, 1} => :native_term,
    {Kernel, :inspect, 2} => :native_term,
    {Kernel, :to_string, 1} => :native_term,
    {Kernel, :is_atom, 1} => :native_term,
    {Kernel, :is_binary, 1} => :native_term,
    {Kernel, :is_integer, 1} => :native_term,
    {Kernel, :is_float, 1} => :native_term,
    {Kernel, :is_list, 1} => :native_term,
    {Kernel, :is_map, 1} => :native_term,
    {Kernel, :is_tuple, 1} => :native_term,
    {Kernel, :self, 0} => :native_term,
    {Kernel, :send, 2} => :native_term,
    {Kernel, :spawn, 1} => :native_term,
    {:erlang, :length, 1} => :native_term,
    {:erlang, :hd, 1} => :native_term,
    {:erlang, :tl, 1} => :native_term,
    {:erlang, :tuple_size, 1} => :native_term,
    {:erlang, :byte_size, 1} => :native_term,
    {:erlang, :map_size, 1} => :native_term,
    {:erlang, :list_to_binary, 1} => :native_term,
    {:erlang, :binary_to_float, 1} => :native_term,
    {:erlang, :split_binary, 2} => :native_term,
    {:erlang, :is_atom, 1} => :native_term,
    {:erlang, :is_binary, 1} => :native_term,
    {:erlang, :is_integer, 1} => :native_term,
    {:erlang, :is_float, 1} => :native_term,
    {:erlang, :is_list, 1} => :native_term,
    {:erlang, :is_map, 1} => :native_term,
    {:erlang, :is_tuple, 1} => :native_term,
    {:erlang, :self, 0} => :native_term,
    {:erlang, :send, 2} => :native_term,
    {:erlang, :exit, 2} => :native_term,
    {:erlang, :link, 1} => :native_term,
    {:erlang, :unlink, 1} => :native_term,
    {:erlang, :monitor, 2} => :native_term,
    {:erlang, :demonitor, 1} => :native_term,
    {:erlang, :process_flag, 2} => :native_term,
    {:erlang, :monotonic_time, 0} => :native_term,
    {:erlang, :monotonic_time, 1} => :native_term,
    {:erlang, :unique_integer, 0} => :native_term,
    {:erlang, :unique_integer, 1} => :native_term
  }

  @doc "Returns kernel-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.List do
  @moduledoc """
  List-domain declarations.
  """

  @class_map %{
    {List, :first, 1} => :native_term,
    {:lists, :keyfind, 3} => :native_term,
    {:lists, :reverse, 1} => :native_term,
    {:lists, :reverse, 2} => :native_term
  }

  @doc "Returns list-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Keyword do
  @moduledoc "Keyword-list lookup declarations."

  @class_map %{
    {Keyword, :get, 2} => :native_term,
    {Keyword, :get, 3} => :native_term
  }

  @doc "Returns keyword-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Date do
  @moduledoc """
  Date-domain declarations. Dates use Gregorian day counts in the current
  slice; the registry exposes only operations with a native replacement for
  that representation.
  """

  @class_map %{
    {Date, :to_iso8601, 1} => :native_term
  }

  @doc "Returns date-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Time do
  @moduledoc """
  Time-domain declarations. Times use a packed integer in the current slice;
  the registry exposes only operations with a native replacement for that
  representation.
  """

  @class_map %{
    {Time, :to_iso8601, 1} => :native_term
  }

  @doc "Returns time-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.NaiveDateTime do
  @moduledoc """
  NaiveDateTime-domain declarations. Naive datetimes use a packed integer in
  the current slice; the registry exposes only operations with a native
  replacement for that representation.
  """

  @class_map %{
    {NaiveDateTime, :to_iso8601, 1} => :native_term
  }

  @doc "Returns naive-datetime-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Process do
  @moduledoc """
  Process supervision primitives backed by the native actor runtime.
  """

  @class_map %{
    {Process, :exit, 2} => :native_term,
    {Process, :link, 1} => :native_term,
    {Process, :unlink, 1} => :native_term,
    {Process, :monitor, 1} => :native_term,
    {Process, :demonitor, 1} => :native_term,
    {Process, :flag, 2} => :native_term
  }

  @doc "Returns process-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Map do
  @moduledoc """
  Map-domain declarations.
  """

  @class_map %{
    {Map, :size, 1} => :native_term,
    {Map, :put, 3} => :native_term
  }

  @doc "Returns map-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Tuple do
  @moduledoc """
  Tuple-domain declarations. `tuple_size`/`elem` also live in `Kernel`;
  the size entry is re-declared so module-qualified calls resolve too.
  """

  @class_map %{
    {Tuple, :size, 1} => :native_term,
    {Tuple, :delete_at, 2} => :unsupported,
    {Tuple, :insert_at, 3} => :unsupported
  }

  @doc "Returns tuple-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Binary do
  @moduledoc """
  Binary-domain declarations.
  """

  @class_map %{
    {:binary, :at, 2} => :native_term,
    {:binary, :match, 2} => :native_term,
    {Binary, :part, 3} => :unsupported
  }

  @doc "Returns binary-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.MapSet do
  @moduledoc """
  MapSet-domain declarations. Sets are represented as deduplicated lists in
  the slice; `Enum` operations over them reuse the list paths.
  """

  @class_map %{
    {MapSet, :new, 1} => :native_term,
    {MapSet, :member?, 2} => :native_term,
    {MapSet, :put, 2} => :native_term
  }

  @doc "Returns mapset-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.HashSet do
  @moduledoc """
  HashSet-domain declarations (alias of the MapSet representation).
  """

  @class_map %{
    {HashSet, :new, 1} => :native_term
  }

  @doc "Returns hashset-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Stream do
  @moduledoc """
  Stream-domain declarations. `map`/`filter` are handled by recognition;
  `take`/`drop` lower to runtime list slicing.
  """

  @class_map %{
    {Stream, :take, 2} => :native_term,
    {Stream, :drop, 2} => :native_term
  }

  @doc "Returns stream-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.File do
  @moduledoc """
  File-domain declarations. `File.read!`/`File.stream!` read through the
  runtime (eager lines for streams).
  """

  @class_map %{
    {File, :read!, 1} => :native_term,
    {File, :stream!, 1} => :native_term
  }

  @doc "Returns file-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.String do
  @moduledoc """
  String-domain declarations.
  """

  @class_map %{
    {String, :length, 1} => :native_term,
    {String, :printable?, 1} => :native_term,
    {String, :to_integer, 1} => :native_term,
    {String, :to_float, 1} => :native_term
  }

  @doc "Returns string-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.IO do
  @moduledoc """
  IO-domain declarations.
  """

  @class_map %{
    {IO, :iodata_to_binary, 1} => :native_term,
    {:erlang, :iolist_to_binary, 1} => :native_term
  }

  @doc "Returns IO-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Base do
  @moduledoc """
  Base-domain declarations.
  """

  @class_map %{
    {Base, :encode16, 1} => :native_term,
    {Base, :decode16, 1} => :native_term
  }

  @doc "Returns base-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Integer do
  @moduledoc """
  Integer-domain declarations.
  """

  @class_map %{
    {Integer, :to_charlist, 1} => :native_term,
    {Integer, :to_string, 1} => :native_term
  }

  @doc "Returns integer-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Enum do
  @moduledoc """
  Enum-domain declarations. The first slice declares the surface only:
  lowering arrives with the BEAM callback bridge (protocol consolidation).
  """

  @class_map %{
    {Enum, :count, 1} => :native_term,
    {Enum, :map, 2} => :beamer_callback,
    {Enum, :reduce, 3} => :beamer_callback,
    {Enum, :to_list, 1} => :native_term
  }

  @doc "Returns enum-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib do
  @moduledoc """
  Stdlib domain registry: which `{module, function, arity}` entries the
  compiler can replace natively, and how.

  Declaration-first, mirroring the term ABI manifest: the registry owns the
  surface, the lowering owns the codegen. Every entry maps to a replacement
  class:

    - `:native_term` — lowered to `ex.term.*` runtime intrinsics or `ex.is_*`
      ops in the current slice;
    - `:beamer_callback` — declared for BEAM callback interop (Kinda /
      protocol consolidation), not yet lowered;
    - `:unsupported` — declared but no lowering exists yet; calls raise
      explicitly instead of being silently dropped.

  Anything not declared raises explicitly at lift time. Each declaration also
  receives effect and reduction metadata through `plan/1`; this is the gate
  used to distinguish resumable loop safe points from blocking or constant
  runtime calls.
  """

  @classes Elixir.Enum.reduce(
             [
               Batata.Stdlib.Binary.class_map(),
               Batata.Stdlib.Date.class_map(),
               Batata.Stdlib.Kernel.class_map(),
               Batata.Stdlib.Keyword.class_map(),
               Batata.Stdlib.List.class_map(),
               Batata.Stdlib.Map.class_map(),
               Batata.Stdlib.MapSet.class_map(),
               Batata.Stdlib.NaiveDateTime.class_map(),
               Batata.Stdlib.Process.class_map(),
               Batata.Stdlib.HashSet.class_map(),
               Batata.Stdlib.Stream.class_map(),
               Batata.Stdlib.File.class_map(),
               Batata.Stdlib.IO.class_map(),
               Batata.Stdlib.String.class_map(),
               Batata.Stdlib.Time.class_map(),
               Batata.Stdlib.Base.class_map(),
               Batata.Stdlib.Integer.class_map(),
               Batata.Stdlib.Tuple.class_map(),
               Batata.Stdlib.Enum.class_map()
             ],
             %{},
             &Elixir.Map.merge(&2, &1)
           )

  @raising_mfas MapSet.new([
                  {Kernel, :inspect, 1},
                  {Kernel, :inspect, 2},
                  {Kernel, :to_string, 1},
                  {Date, :to_iso8601, 1},
                  {Integer, :to_charlist, 1},
                  {NaiveDateTime, :to_iso8601, 1},
                  {Time, :to_iso8601, 1},
                  {:erlang, :binary_to_float, 1},
                  {String, :printable?, 1},
                  {Keyword, :get, 2},
                  {Keyword, :get, 3},
                  {:erlang, :split_binary, 2},
                  {:lists, :keyfind, 3},
                  {:lists, :reverse, 1},
                  {:lists, :reverse, 2}
                ])

  @impure_mfas MapSet.new([
                 {Kernel, :self, 0},
                 {Kernel, :send, 2},
                 {Kernel, :spawn, 1},
                 {:erlang, :self, 0},
                 {:erlang, :send, 2},
                 {:erlang, :exit, 2},
                 {:erlang, :link, 1},
                 {:erlang, :unlink, 1},
                 {:erlang, :monitor, 2},
                 {:erlang, :demonitor, 1},
                 {:erlang, :process_flag, 2},
                 {:erlang, :monotonic_time, 0},
                 {:erlang, :monotonic_time, 1},
                 {:erlang, :unique_integer, 0},
                 {:erlang, :unique_integer, 1},
                 {Process, :exit, 2},
                 {Process, :link, 1},
                 {Process, :unlink, 1},
                 {Process, :monitor, 1},
                 {Process, :demonitor, 1},
                 {Process, :flag, 2},
                 {File, :read!, 1},
                 {File, :stream!, 1}
               ])

  @allocating_mfas MapSet.new([
                     {Kernel, :spawn, 1},
                     {Binary, :part, 3},
                     {MapSet, :new, 1},
                     {MapSet, :put, 2},
                     {Map, :put, 3},
                     {Kernel, :list_to_binary, 1},
                     {Kernel, :inspect, 1},
                     {Kernel, :inspect, 2},
                     {Date, :to_iso8601, 1},
                     {NaiveDateTime, :to_iso8601, 1},
                     {Time, :to_iso8601, 1},
                     {IO, :iodata_to_binary, 1},
                     {:erlang, :binary_to_float, 1},
                     {:erlang, :iolist_to_binary, 1},
                     {:erlang, :split_binary, 2},
                     {HashSet, :new, 1},
                     {Stream, :take, 2},
                     {Stream, :drop, 2},
                     {File, :read!, 1},
                     {File, :stream!, 1},
                     {Base, :encode16, 1},
                     {Base, :decode16, 1},
                     {Integer, :to_charlist, 1},
                     {Integer, :to_string, 1},
                     {Enum, :map, 2},
                     {Enum, :to_list, 1},
                     {:lists, :reverse, 1},
                     {:lists, :reverse, 2}
                   ])

  @resumable_mfas MapSet.new([
                    {Enum, :map, 2},
                    {Enum, :reduce, 3},
                    {Keyword, :get, 2},
                    {Keyword, :get, 3},
                    {:lists, :keyfind, 3},
                    {:lists, :reverse, 1},
                    {:lists, :reverse, 2}
                  ])

  @blocking_mfas MapSet.new([
                   {File, :read!, 1},
                   {File, :stream!, 1}
                 ])

  @per_element_mfas MapSet.new([
                      {Enum, :count, 1},
                      {Enum, :map, 2},
                      {Enum, :reduce, 3},
                      {Enum, :to_list, 1},
                      {MapSet, :new, 1},
                      {HashSet, :new, 1},
                      {Keyword, :get, 2},
                      {Keyword, :get, 3},
                      {Stream, :take, 2},
                      {Stream, :drop, 2},
                      {:erlang, :split_binary, 2},
                      {:lists, :keyfind, 3},
                      {:lists, :reverse, 1},
                      {:lists, :reverse, 2}
                    ])

  @doc """
  Returns the replacement class for `{module, function, arity}`, or `nil`
  when the call is outside the declared stdlib surface.
  """
  @spec class({module(), atom(), non_neg_integer()}) :: atom() | nil
  def class({module, function, arity}) do
    Elixir.Map.get(@classes, {module, function, arity})
  end

  @doc """
  Returns a `Batata.Stdlib.Plan` for the declared `{module, function, arity}`,
  or `nil` when the call is outside the declared surface.
  """
  @spec plan({module(), atom(), non_neg_integer()}) :: Batata.Stdlib.Plan.t() | nil
  def plan({_, _, _} = mfa) do
    case class(mfa) do
      nil -> nil
      class -> struct!(Batata.Stdlib.Plan, Map.merge(%{mfa: mfa, class: class}, metadata(mfa)))
    end
  end

  @doc "Effect and reduction metadata for a declared stdlib entry."
  @spec metadata({module(), atom(), non_neg_integer()}) :: map() | nil
  def metadata({_, _, _} = mfa) do
    if Map.has_key?(@classes, mfa) do
      %{
        purity: if(MapSet.member?(@impure_mfas, mfa), do: :impure, else: :pure),
        allocation: if(MapSet.member?(@allocating_mfas, mfa), do: :may_allocate, else: :none),
        preemption: preemption(mfa),
        reductions: reductions(mfa)
      }
    end
  end

  defp preemption(mfa) do
    cond do
      MapSet.member?(@blocking_mfas, mfa) -> :blocking
      MapSet.member?(@resumable_mfas, mfa) -> :resumable
      true -> :none
    end
  end

  defp reductions(mfa) do
    cond do
      MapSet.member?(@blocking_mfas, mfa) -> :external
      MapSet.member?(@per_element_mfas, mfa) -> :per_element
      true -> :constant
    end
  end

  @doc "All declared entries, for diagnostics and tests."
  def classes, do: @classes

  @doc "Returns whether a native replacement can raise through the actor boundary."
  def may_raise?(mfa), do: MapSet.member?(@raising_mfas, mfa)
end
