defmodule Batata.ObjC.Metadata do
  @moduledoc "Loads and verifies the pinned Foundation/AppKit metadata allowlist."

  alias Batata.ObjC.Diagnostic

  @manifest Application.compile_env(
              :batata_objc,
              :metadata_manifest,
              Path.expand("../../../priv/metadata/appkit.json", __DIR__)
            )

  @doc "Loads the checked-in metadata manifest and verifies its content digest."
  @spec load!() :: map()
  def load!, do: load!(@manifest)

  @doc "Loads one manifest path, rejecting malformed JSON and digest drift."
  @spec load!(Path.t()) :: map()
  def load!(path) do
    manifest = read_manifest!(path)
    source = fetch_field!(manifest, "source", path)
    expected = fetch_field!(manifest, "sdk_digest", path)
    actual = "sha256:" <> digest(source)

    if actual != expected do
      raise Diagnostic,
        code: "E_OBJC_SDK_DRIFT",
        message: "Objective-C metadata source digest does not match its receipt",
        context: %{path: Path.expand(path), expected: expected, actual: actual},
        actions: [%{command: "mix batata.objc.metadata --review"}]
    end

    source
    |> Map.put("sdk", fetch_field!(manifest, "sdk", path))
    |> Map.put("sdk_digest", expected)
  end

  defp read_manifest!(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- JSON.decode(contents) do
      manifest
    else
      {:error, reason} -> invalid_manifest!(path, inspect(reason))
      _ -> invalid_manifest!(path, "root JSON value is not an object")
    end
  end

  defp fetch_field!(manifest, field, path) do
    case Map.fetch(manifest, field) do
      {:ok, value} -> value
      :error -> invalid_manifest!(path, "missing #{field}")
    end
  end

  defp invalid_manifest!(path, error) do
    raise Diagnostic,
      code: "E_OBJC_METADATA_INCOMPLETE",
      message: "cannot load Objective-C metadata manifest",
      context: %{path: Path.expand(path), error: error},
      actions: [%{command: "restore priv/metadata/appkit.json from source control"}]
  end

  @doc "Returns the SHA-256 receipt for a JSON-ready metadata source."
  @spec digest(map()) :: String.t()
  def digest(source) when is_map(source) do
    source |> JSON.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
