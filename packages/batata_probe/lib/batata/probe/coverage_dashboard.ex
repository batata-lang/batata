defmodule Batata.Probe.CoverageDashboard do
  @moduledoc "Merges precomputed corpus dashboards without loading the compiler."

  @schema_version 2
  @levels ~w(raw_inventory canonical_acceptance corpus_compile_link semantic_execution)

  @doc "Merges dashboards after validating their schema, contract, and corpus identities."
  @spec merge!([Path.t()], Path.t()) :: map()
  def merge!(inputs, output) when is_list(inputs) and inputs != [] do
    dashboards = Enum.map(inputs, &read_json!/1)
    [first | rest] = dashboards
    validate_dashboard!(first)

    corpora =
      Enum.reduce(rest, first["corpora"], fn dashboard, corpora ->
        validate_dashboard!(dashboard)

        unless dashboard["levels"] == first["levels"] and
                 dashboard["coverage_claim"] == first["coverage_claim"] do
          raise ArgumentError, "coverage dashboard contracts do not match"
        end

        Map.merge(corpora, dashboard["corpora"], fn name, _left, _right ->
          raise ArgumentError, "duplicate coverage corpus #{name}"
        end)
      end)

    merged = Map.put(first, "corpora", corpora)
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, JSON.encode!(merged))
    merged
  end

  defp validate_dashboard!(%{
         "schema_version" => @schema_version,
         "coverage_claim" => claim,
         "levels" => @levels,
         "corpora" => corpora
       })
       when is_binary(claim) and is_map(corpora) and map_size(corpora) > 0,
       do: :ok

  defp validate_dashboard!(_dashboard) do
    raise ArgumentError, "invalid coverage dashboard"
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
end
