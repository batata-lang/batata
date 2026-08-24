defmodule Batata.Memory.CanonicalJSON do
  @moduledoc false

  @spec encode!(term()) :: String.t()
  def encode!(value), do: encode_value(value)

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_binary(value), do: JSON.encode!(value)
  defp encode_value(value) when is_atom(value), do: value |> Atom.to_string() |> JSON.encode!()

  defp encode_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ",", &encode_value/1) <> "]"
  end

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.map(fn {key, entry_value} -> {normalize_key!(key), entry_value} end)
      |> reject_duplicate_keys!()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, entry_value} ->
        JSON.encode!(key) <> ":" <> encode_value(entry_value)
      end)

    "{" <> entries <> "}"
  end

  defp encode_value(value) do
    raise ArgumentError,
          "canonical memory JSON supports only null, booleans, integers, strings, atoms, " <>
            "lists, and maps with string or atom keys; got: #{inspect(value)}"
  end

  defp normalize_key!(key) when is_binary(key), do: key
  defp normalize_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_key!(key) do
    raise ArgumentError,
          "canonical memory JSON key must be a string or atom, got: #{inspect(key)}"
  end

  defp reject_duplicate_keys!(entries) do
    case entries
         |> Enum.frequencies_by(&elem(&1, 0))
         |> Enum.find(fn {_key, count} -> count > 1 end) do
      nil -> entries
      {key, _count} -> raise ArgumentError, "duplicate canonical memory JSON key: #{inspect(key)}"
    end
  end
end
