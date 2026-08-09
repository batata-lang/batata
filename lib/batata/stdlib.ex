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
    {Kernel, :is_atom, 1} => :native_term,
    {Kernel, :is_binary, 1} => :native_term,
    {Kernel, :is_integer, 1} => :native_term,
    {Kernel, :is_list, 1} => :native_term,
    {Kernel, :is_map, 1} => :native_term,
    {Kernel, :is_tuple, 1} => :native_term,
    {Kernel, :self, 0} => :native_term,
    {Kernel, :send, 2} => :native_term,
    {:erlang, :length, 1} => :native_term,
    {:erlang, :hd, 1} => :native_term,
    {:erlang, :tl, 1} => :native_term,
    {:erlang, :tuple_size, 1} => :native_term,
    {:erlang, :byte_size, 1} => :native_term,
    {:erlang, :map_size, 1} => :native_term,
    {:erlang, :is_atom, 1} => :native_term,
    {:erlang, :is_binary, 1} => :native_term,
    {:erlang, :is_integer, 1} => :native_term,
    {:erlang, :is_list, 1} => :native_term,
    {:erlang, :is_map, 1} => :native_term,
    {:erlang, :is_tuple, 1} => :native_term,
    {:erlang, :self, 0} => :native_term,
    {:erlang, :send, 2} => :native_term
  }

  @doc "Returns kernel-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.List do
  @moduledoc """
  List-domain declarations.
  """

  @class_map %{
    {List, :first, 1} => :native_term
  }

  @doc "Returns list-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.Map do
  @moduledoc """
  Map-domain declarations.
  """

  @class_map %{
    {Map, :size, 1} => :native_term
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
    {Binary, :part, 3} => :unsupported
  }

  @doc "Returns binary-domain stdlib replacement declarations."
  def class_map, do: @class_map
end

defmodule Batata.Stdlib.String do
  @moduledoc """
  String-domain declarations.
  """

  @class_map %{
    {String, :length, 1} => :native_term,
    {String, :to_integer, 1} => :native_term
  }

  @doc "Returns string-domain stdlib replacement declarations."
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
    {Enum, :to_list, 1} => :beamer_callback
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

  Anything not declared raises explicitly at lift time.
  """

  @classes Elixir.Enum.reduce(
             [
               Batata.Stdlib.Binary.class_map(),
               Batata.Stdlib.Kernel.class_map(),
               Batata.Stdlib.List.class_map(),
               Batata.Stdlib.Map.class_map(),
               Batata.Stdlib.String.class_map(),
               Batata.Stdlib.Base.class_map(),
               Batata.Stdlib.Integer.class_map(),
               Batata.Stdlib.Tuple.class_map(),
               Batata.Stdlib.Enum.class_map()
             ],
             %{},
             &Elixir.Map.merge(&2, &1)
           )

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
      class -> %Batata.Stdlib.Plan{mfa: mfa, class: class}
    end
  end

  @doc "All declared entries, for diagnostics and tests."
  def classes, do: @classes
end
