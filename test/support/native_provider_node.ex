defmodule Batata.TestNativeProviderNode do
  @moduledoc "A project-local IR node contributing a native plan, for tests."
  defstruct [:plan, :original]
end

defimpl Batata.Native.Provider, for: Batata.TestNativeProviderNode do
  def native_plan(%{plan: %Batata.Stdlib.Plan{} = plan}), do: plan
  def native_plan(_node), do: nil
end
