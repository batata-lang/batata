defmodule Batata.Wings.Native.Source do
  @moduledoc "The checked-in, shared source boundary for the native Wings kernel."

  @source_path Path.expand("kernel.ex", __DIR__)
  @external_resource @source_path

  @doc "Returns the exact source compiled by both Mix and Batata AOT."
  @spec read!() :: String.t()
  def read!, do: File.read!(@source_path)

  @doc "Returns the repository-relative source identity used by artifact receipts."
  @spec identity() :: map()
  def identity do
    source = read!()

    %{
      "module" => "Batata.Wings.Native.Kernel",
      "source" => "packages/batata_wings/lib/batata/wings/native/kernel.ex",
      "source_sha256" => source |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    }
  end
end
