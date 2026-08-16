defmodule Batata.NativeDeps do
  @moduledoc false

  @root Path.expand("../../../..", __DIR__)

  def root(opts \\ []), do: Path.expand(opts[:root] || @root)

  def config_path(opts \\ []),
    do: opts[:config_path] || Path.join([root(opts), ".batata", "native.config"])

  def lock_path(opts \\ []), do: opts[:lock_path] || Path.join(root(opts), "native-deps.lock")

  def lock!(opts \\ []) do
    lock_path(opts)
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, deps ->
      case String.split(String.trim(line), "=", parts: 2) do
        [key, value] when key != "" and value != "" -> Map.put(deps, key, value)
        _ -> deps
      end
    end)
  end

  def config!(opts \\ []) do
    path = config_path(opts)

    case :file.consult(String.to_charlist(path)) do
      {:ok, [config]} when is_list(config) ->
        config

      {:error, :enoent} ->
        Mix.raise("native dependencies are not configured; run 'mix batata.native setup'")

      {:ok, _other} ->
        Mix.raise("expected one keyword-list term in #{path}")

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{inspect(reason)}")
    end
  end

  def write_config!(config, opts \\ []) do
    path = config_path(opts)
    File.mkdir_p!(Path.dirname(path))
    content = :io_lib.format(~c"~tp.~n", [config]) |> IO.iodata_to_binary()
    File.write!(path, content)
  end

  def cache_root(opts \\ []) do
    opts[:cache_root] ||
      case :filename.basedir(:user_cache, "batata") do
        path when is_binary(path) -> path
        path when is_list(path) -> List.to_string(path)
      end
  end

  def digest(values, length \\ 16) do
    values
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end

  def executable(name) do
    if match?({:win32, _}, :os.type()), do: name <> ".exe", else: name
  end
end
