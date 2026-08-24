defmodule Batata.Stdlib.Plan do
  @moduledoc """
  Native replacement plan carried by `Batata.Native.Provider` implementations.

  `class` mirrors the replacement classes of the `Batata.Stdlib` registry
  (`:native_term`, `:beamer_callback`, `:unsupported`); `mfa` identifies the
  stdlib entry the plan replaces. The remaining fields make effects and yield
  safety explicit before lowering:

    * `purity` is `:pure` or `:impure`;
    * `allocation` is `:none`, `:may_allocate`, or `:unknown`;
    * `preemption` is `:none`, `:resumable`, or `:blocking`;
    * `reductions` is `:constant`, `:per_element`, or `:external`.

  A lowering may only introduce a yield at a `:resumable` plan. In
  particular, `:blocking` identifies work that must move behind an async
  runtime boundary rather than being mistaken for a safe point.
  """

  @enforce_keys [:mfa, :class]
  defstruct [
    :mfa,
    :class,
    purity: :pure,
    allocation: :unknown,
    preemption: :none,
    reductions: :constant
  ]

  @type t() :: %__MODULE__{
          mfa: {module(), atom(), non_neg_integer()},
          class: atom(),
          purity: :pure | :impure,
          allocation: :none | :may_allocate | :unknown,
          preemption: :none | :resumable | :blocking,
          reductions: :constant | :per_element | :external
        }
end
