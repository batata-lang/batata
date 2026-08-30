defmodule Batata.CompilerKernel do
  @moduledoc """
  Batata-owned production compiler-kernel artifacts for Ex conversion.

  Beaver owns the provider-neutral ABI, loader, trampoline, and frozen Stage 0
  seed. This package owns the evolving Batata conversion source, shared
  library, manifest instance, and Stage 1/2 receipts. Beaver never depends on
  this package or on its release layout.
  """

  @provider "batata.ex-conversion"
  @sidecar "compiler-kernel.json"

  @doc "Stable provider identity used in Beaver compiler-kernel manifests."
  @spec provider() :: String.t()
  def provider, do: @provider

  @doc "Canonical sidecar filename emitted next to the native library."
  @spec sidecar_name() :: String.t()
  def sidecar_name, do: @sidecar

  @doc "Path to the versioned clean-bootstrap seed policy shipped by this package."
  @spec seed_manifest_path() :: Path.t()
  def seed_manifest_path do
    :batata_compiler_kernel
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("bootstrap/seed-manifest.json")
  end

  @doc "Reads the checked-in Stage 0 seed policy."
  @spec seed_manifest!() :: map()
  def seed_manifest!, do: seed_manifest_path() |> File.read!() |> JSON.decode!()

  @doc false
  @spec conversion_source_path() :: Path.t()
  def conversion_source_path,
    do: application_path("source/ex_conversion.ex")

  @doc false
  @spec native_adapter_path() :: Path.t()
  def native_adapter_path,
    do: application_path("native/compiler_kernel_adapter.c")

  defp application_path(relative) do
    :batata_compiler_kernel
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join(relative)
  end
end
