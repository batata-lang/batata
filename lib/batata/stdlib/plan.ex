defmodule Batata.Stdlib.Plan do
  @moduledoc """
  Native replacement plan carried by `Batata.Native.Provider` implementations.

  `class` mirrors the replacement classes of the `Batata.Stdlib` registry
  (`:native_term`, `:beamer_callback`, `:unsupported`); `mfa` identifies the
  stdlib entry the plan replaces.
  """

  @enforce_keys [:mfa, :class]
  defstruct [:mfa, :class]

  @type t() :: %__MODULE__{mfa: {module(), atom(), non_neg_integer()}, class: atom()}
end
