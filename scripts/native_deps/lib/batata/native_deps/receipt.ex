defmodule Batata.NativeDeps.Receipt do
  @moduledoc false

  alias Batata.NativeDeps
  alias Batata.NativeDeps.Command

  @observational_keys ["batata_commit"]

  def write!(config, opts \\ []) do
    receipt = build!(config, opts)
    path = NativeDeps.receipt_path(opts)
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, [:json.encode(receipt), "\n"])
    File.rename!(temporary, path)
    receipt
  end

  def verify!(config, opts \\ []) do
    expected = build!(config, opts)
    actual = read!(opts)

    comparable = fn receipt -> Map.drop(receipt, @observational_keys) end

    unless comparable.(actual) == comparable.(expected) do
      changed =
        (Map.keys(actual) ++ Map.keys(expected))
        |> Enum.uniq()
        |> Enum.reject(&(Map.get(actual, &1) == Map.get(expected, &1)))
        |> Enum.sort()
        |> Enum.join(", ")

      Mix.raise(
        "native dependency receipt is stale#{if changed == "", do: "", else: " (changed: #{changed})"}; " <>
          "run 'mix batata.native setup'"
      )
    end

    actual
  end

  def build!(config, opts \\ []) do
    llvm_config = Keyword.fetch!(config, :llvm_config_path)

    zig =
      opts[:zig_path] || System.find_executable("zig") ||
        Mix.raise("zig is required but was not found")

    tools = %{
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version(),
      "zig" => command!(zig, ["version"])
    }

    llvm = %{
      "config" => llvm_config,
      "revision" => Keyword.fetch!(config, :llvm_revision) |> to_string(),
      "source" => Keyword.fetch!(config, :llvm_source) |> to_string(),
      "version" => command!(llvm_config, ["--version"]),
      "libdir" => command!(llvm_config, ["--libdir"]),
      "includedir" => command!(llvm_config, ["--includedir"])
    }

    receipt = %{
      "schema" => 1,
      "mode" => Keyword.fetch!(config, :mode) |> to_string(),
      "batata_commit" => git_revision(NativeDeps.root(opts)),
      "lock_sha256" => Keyword.fetch!(config, :lock_sha256),
      "beaver_metadata_sha256" => Keyword.fetch!(config, :beaver_metadata_sha256),
      "beaver" => source(config, :beaver),
      "kinda" => source(config, :kinda),
      "llvm" => llvm,
      "tools" => tools
    }

    Map.put(receipt, "configuration_hash", configuration_hash(receipt))
  end

  defp read!(opts) do
    path = NativeDeps.receipt_path(opts)

    with {:ok, content} <- File.read(path),
         {:ok, receipt} <- decode_json(content),
         %{"schema" => 1} <- receipt do
      receipt
    else
      {:error, :enoent} ->
        Mix.raise("native dependency receipt is missing; run 'mix batata.native setup'")

      {:error, reason} ->
        Mix.raise("cannot read native dependency receipt at #{path}: #{inspect(reason)}")

      _ ->
        Mix.raise("native dependency receipt at #{path} has an unsupported schema")
    end
  end

  defp source(config, name) do
    %{
      "path" => Keyword.fetch!(config, key(name, :path)),
      "commit" => Keyword.fetch!(config, key(name, :ref)),
      "source" => Keyword.fetch!(config, key(name, :source)) |> to_string()
    }
  end

  defp key(name, suffix), do: String.to_existing_atom("#{name}_#{suffix}")

  defp configuration_hash(receipt) do
    receipt
    |> Map.drop(["batata_commit", "configuration_hash"])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp git_revision(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      _ -> "unversioned"
    end
  end

  defp command!(command, args), do: Command.run!(command, args) |> String.trim()

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    error -> {:error, error}
  end
end
