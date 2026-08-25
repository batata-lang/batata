defmodule Batata.Memory.RuntimeQuota do
  @moduledoc "The physical execution-arena limit shared by analysis and Lower."

  @hard_limit_bytes 128 * 64 * 1024 * 8

  @doc "Returns the native segmented-arena hard limit in bytes."
  @spec hard_limit_bytes() :: pos_integer()
  def hard_limit_bytes, do: @hard_limit_bytes

  @doc "Validates an optional user quota against the physical runtime limit."
  @spec validate!(term()) :: nil | non_neg_integer()
  def validate!(nil), do: nil

  def validate!(bytes)
      when is_integer(bytes) and bytes >= 0 and bytes <= @hard_limit_bytes,
      do: bytes

  def validate!(bytes) do
    raise ArgumentError,
          "memory_quota_bytes must be a non-negative integer no greater than " <>
            "#{@hard_limit_bytes}, got: #{inspect(bytes)}"
  end

  @doc "Returns the limit the native runtime will enforce."
  @spec effective_bytes(nil | non_neg_integer()) :: non_neg_integer()
  def effective_bytes(nil), do: @hard_limit_bytes
  def effective_bytes(bytes), do: bytes

  @doc "Returns the canonical physical limit descriptor embedded in plans and receipts."
  @spec descriptor(nil | non_neg_integer()) :: map()
  def descriptor(quota_bytes) do
    %{
      "effective_bytes" => quota_bytes |> effective_bytes() |> Integer.to_string(),
      "enforcement" => "native-runtime",
      "hard_limit_bytes" => Integer.to_string(@hard_limit_bytes),
      "id" => "execution-arena",
      "scope" => "per-runtime-execution"
    }
  end

  @doc "Returns the accepted typed failure guard for an explicit quota."
  @spec guard(non_neg_integer()) :: map()
  def guard(bytes) do
    %{
      "failure_effect" => "arena_oom",
      "id" => "execution-arena-quota",
      "maximum_bytes" => Integer.to_string(bytes)
    }
  end
end
