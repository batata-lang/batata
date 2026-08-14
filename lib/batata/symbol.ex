defmodule Batata.Symbol do
  @moduledoc "Defines collision-free internal symbols shared by Lift and AOT metadata."

  @reserved_functions [:__batata_entry, :__fn_dispatch]

  @spec function(atom(), non_neg_integer()) :: String.t()
  def function(name, _arity) when name in @reserved_functions, do: Atom.to_string(name)

  def function(name, arity) when is_atom(name) and is_integer(arity) and arity >= 0 do
    encoded_name = name |> Atom.to_string() |> Base.encode16(case: :lower)
    "__batata_fn_#{encoded_name}_#{arity}"
  end
end
