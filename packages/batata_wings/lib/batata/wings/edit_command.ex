defmodule Batata.Wings.EditCommand do
  @moduledoc "A closed, replayable geometry edit request."

  alias Batata.Wings.{CanonicalJSON, Diagnostic}

  @operations [:select, :move, :extrude, :inset, :bevel, :undo, :redo]
  @default_quota_bytes 64 * 1024 * 1024

  @enforce_keys [
    :operation,
    :arguments,
    :source_mesh_digest,
    :expected_generation,
    :quota_bytes
  ]
  defstruct @enforce_keys

  @type operation :: :select | :move | :extrude | :inset | :bevel | :undo | :redo
  @type t :: %__MODULE__{
          operation: operation(),
          arguments: map(),
          source_mesh_digest: binary(),
          expected_generation: non_neg_integer(),
          quota_bytes: pos_integer()
        }

  @spec new!(operation(), map(), binary(), non_neg_integer(), keyword()) :: t()
  def new!(operation, arguments, source_mesh_digest, expected_generation, options \\ []) do
    quota = Keyword.get(options, :quota_bytes, @default_quota_bytes)

    unless operation in @operations and is_map(arguments) and is_binary(source_mesh_digest) and
             is_integer(expected_generation) and expected_generation >= 0 and is_integer(quota) and
             quota > 0 do
      raise Diagnostic.new!(
              "E_WINGS_EDIT_PRECONDITION_FAILED",
              "edit command does not satisfy the closed command schema",
              %{
                "expected_generation" => expected_generation,
                "operation" => inspect(operation),
                "quota_bytes" => quota,
                "source_mesh_digest" => inspect(source_mesh_digest)
              },
              [%{"command" => "construct a command with a declared operation and positive quota"}]
            )
    end

    command = %__MODULE__{
      operation: operation,
      arguments: arguments,
      source_mesh_digest: source_mesh_digest,
      expected_generation: expected_generation,
      quota_bytes: quota
    }

    canonical_map(command)
    command
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = command) do
    %{
      "arguments" => command.arguments,
      "expected_generation" => command.expected_generation,
      "operation" => Atom.to_string(command.operation),
      "quota_bytes" => command.quota_bytes,
      "source_mesh_digest" => command.source_mesh_digest
    }
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = command) do
    command
    |> canonical_map()
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
