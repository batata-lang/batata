defmodule Batata.Probe.CapabilityMatrix do
  @moduledoc "Loads and validates executable semantic capability manifests."

  @statuses ~w(executable shaped blocked)
  @owners ~w(frontend lift lower runtime probe)

  def load!(path) do
    matrix = path |> File.read!() |> JSON.decode!()
    validate!(matrix)
  end

  def validate!(%{"schema_version" => 1, "capabilities" => capabilities} = matrix)
      when is_list(capabilities) do
    ids = Enum.map(capabilities, &validate_capability!/1)

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "capability ids must be unique"
    end

    matrix
  end

  def validate!(_matrix), do: raise(ArgumentError, "unsupported capability matrix schema")

  defp validate_capability!(%{"id" => id, "status" => status} = capability)
       when is_binary(id) and status in @statuses do
    case status do
      "blocked" ->
        unless capability["owner"] in @owners and is_binary(capability["reason"]) do
          raise ArgumentError, "blocked capability #{id} needs owner and reason"
        end

      _ ->
        unless is_binary(capability["gate"]) do
          raise ArgumentError, "#{status} capability #{id} needs an executable gate"
        end
    end

    id
  end

  defp validate_capability!(capability) do
    raise ArgumentError, "invalid capability entry: #{inspect(capability)}"
  end
end
