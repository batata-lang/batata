defmodule Batata.Probe.BlockerIdentity do
  @moduledoc false

  @identity_fields ~w(path module line reason form)

  @spec put_id(map()) :: map()
  def put_id(entry) do
    identity = Enum.map_join(@identity_fields, "\0", &to_string(entry[&1]))
    Map.put(entry, "id", digest(identity))
  end

  @spec id(String.t(), String.t(), map()) :: String.t()
  def id(path, module, unsupported) do
    %{
      "path" => path,
      "module" => module,
      "line" => unsupported.line,
      "reason" => to_string(unsupported.reason),
      "form" => unsupported.form
    }
    |> put_id()
    |> Map.fetch!("id")
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
