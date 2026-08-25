defmodule Batata.ObjC.Ownership do
  @moduledoc "Produces closed memory-effect summaries for Objective-C selectors."

  alias Batata.ObjC.BindingPlan

  @doc "Returns a deterministic external-call summary for every selector."
  @spec summaries(BindingPlan.t()) :: [map()]
  def summaries(%BindingPlan{} = plan) do
    Enum.map(plan.selectors, fn selector ->
      %{
        "allocation" => allocation(selector.returns, selector.ownership),
        "callee" => "-[#{selector.class} #{selector.name}]",
        "escape" => escape(selector.ownership),
        "ownership" => Atom.to_string(selector.ownership),
        "thread" => Atom.to_string(selector.thread)
      }
    end)
  end

  defp allocation({:object, _class}, :retained), do: "transfer_owned"
  defp allocation({:object, _class, :nullable}, :retained), do: "transfer_owned_nullable"
  defp allocation({:object, _class}, :autoreleased), do: "autorelease_scope"
  defp allocation({:object, _class, :nullable}, :autoreleased), do: "autorelease_scope_nullable"
  defp allocation(_returns, _ownership), do: "none"

  defp escape(:weak), do: "caller_must_root_argument"
  defp escape(:retained), do: "owned_result"
  defp escape(:autoreleased), do: "borrowed_until_pool_pop"
  defp escape(:borrowed), do: "borrowed_result"
  defp escape(:none), do: "none"
end
