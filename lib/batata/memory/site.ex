defmodule Batata.Memory.Site do
  @moduledoc "Stable identity and display provenance for one memory-analysis site."

  alias Batata.Memory

  @enforce_keys [:id, :module, :function, :semantic_path, :structural_digest, :provenance]
  defstruct [
    :id,
    :module,
    :function,
    :semantic_path,
    :structural_digest,
    :source_span,
    :provenance,
    ir_location: "unknown"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          module: String.t(),
          function: String.t(),
          semantic_path: [String.t()],
          structural_digest: String.t(),
          source_span: String.t() | nil,
          provenance: :structural | :source,
          ir_location: String.t()
        }

  @doc "Builds an identity whose digest does not depend on display-only source metadata."
  @spec structural!(keyword()) :: t()
  def structural!(opts) when is_list(opts) do
    module = opts |> Keyword.fetch!(:module) |> normalize_name!(:module)

    function =
      opts |> Keyword.fetch!(:function) |> normalize_function!(Keyword.fetch!(opts, :arity))

    semantic_path = opts |> Keyword.fetch!(:semantic_path) |> normalize_path!()
    identity = Keyword.fetch!(opts, :identity)

    structural_digest =
      Memory.digest(%{
        "function" => function,
        "identity" => identity,
        "module" => module,
        "semantic_path" => semantic_path
      })

    %__MODULE__{
      id: "mem://#{URI.encode(module)}/#{URI.encode(function)}/site/sha256:#{structural_digest}",
      module: module,
      function: function,
      semantic_path: semantic_path,
      structural_digest: structural_digest,
      source_span: Keyword.get(opts, :source_span),
      provenance: Keyword.get(opts, :provenance, :structural),
      ir_location: Keyword.get(opts, :ir_location, "unknown")
    }
    |> validate!()
  end

  @doc "Converts a site into a canonical JSON-ready map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = site) do
    %{
      "function" => site.function,
      "id" => site.id,
      "ir_location" => site.ir_location,
      "module" => site.module,
      "provenance" => Atom.to_string(site.provenance),
      "semantic_path" => site.semantic_path,
      "source_span" => site.source_span,
      "structural_digest" => site.structural_digest
    }
  end

  defp validate!(%__MODULE__{} = site) do
    unless site.provenance in [:structural, :source] do
      raise ArgumentError, "memory site provenance must be :structural or :source"
    end

    if site.provenance == :source and not is_binary(site.source_span) do
      raise ArgumentError, "source-provenance memory site requires :source_span"
    end

    unless is_binary(site.ir_location) do
      raise ArgumentError, "memory site :ir_location must be a string"
    end

    site
  end

  defp normalize_name!(value, _field) when is_atom(value), do: Atom.to_string(value)
  defp normalize_name!(value, _field) when is_binary(value) and value != "", do: value

  defp normalize_name!(value, field) do
    raise ArgumentError,
          "memory site #{inspect(field)} must be a non-empty atom or string, got: #{inspect(value)}"
  end

  defp normalize_function!(name, arity) when is_integer(arity) and arity >= 0 do
    normalize_name!(name, :function) <> "/" <> Integer.to_string(arity)
  end

  defp normalize_function!(_name, arity) do
    raise ArgumentError,
          "memory site arity must be a non-negative integer, got: #{inspect(arity)}"
  end

  defp normalize_path!(path) when is_list(path) and path != [] do
    Enum.map(path, &normalize_name!(&1, :semantic_path))
  end

  defp normalize_path!(path) do
    raise ArgumentError,
          "memory site semantic path must be a non-empty list, got: #{inspect(path)}"
  end
end
