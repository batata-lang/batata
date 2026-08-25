defmodule Batata.Wings.CanonicalJSON do
  @moduledoc false

  @spec encode!(term()) :: binary()
  def encode!(value), do: value |> encode_value() |> IO.iodata_to_binary()

  defp encode_value(value) when is_map(value) do
    fields =
      value
      |> Enum.map(fn {key, item} -> {key_string!(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> reject_duplicate_keys!()
      |> Enum.map(fn {key, item} -> [JSON.encode!(key), ?:, encode_value(item)] end)
      |> Enum.intersperse(?,)

    [?{, fields, ?}]
  end

  defp encode_value(value) when is_list(value) do
    [?[, value |> Enum.map(&encode_value/1) |> Enum.intersperse(?,), ?]]
  end

  defp encode_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: JSON.encode!(value)

  defp encode_value(value) do
    raise ArgumentError, "canonical JSON cannot encode #{inspect(value)}"
  end

  defp key_string!(key) when is_binary(key), do: key
  defp key_string!(key) when is_atom(key), do: Atom.to_string(key)

  defp key_string!(key),
    do: raise(ArgumentError, "canonical JSON map key is not text: #{inspect(key)}")

  defp reject_duplicate_keys!(fields) do
    case Enum.chunk_every(fields, 2, 1, :discard)
         |> Enum.find(fn [{left, _}, {right, _}] -> left == right end) do
      nil ->
        fields

      [{key, _}, _] ->
        raise ArgumentError, "canonical JSON map contains duplicate key #{inspect(key)}"
    end
  end
end
