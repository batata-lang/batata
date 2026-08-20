defmodule Batata.NativeDeps.Workspace do
  @moduledoc false

  alias Batata.NativeDeps

  def path(opts \\ []) do
    opts[:workspace_path] || Path.join([NativeDeps.root(opts), ".batata", "workspace.json"])
  end

  def load!(opts \\ []) do
    path = path(opts)

    case File.read(path) do
      {:ok, content} ->
        with {:ok, workspace} <- decode_json(content),
             %{"schema" => 1, "mode" => "editable"} <- workspace,
             true <- valid_path?(workspace["beaver_path"]),
             true <- valid_path?(workspace["kinda_path"]),
             true <- is_binary(workspace["beaver_path"]) or is_binary(workspace["kinda_path"]) do
          [
            beaver_path: workspace["beaver_path"],
            kinda_path: workspace["kinda_path"],
            path: path
          ]
        else
          _ ->
            Mix.raise(
              "editable workspace at #{path} must use schema 1, mode editable, " <>
                "and declare beaver_path and/or kinda_path"
            )
        end

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Mix.raise("cannot read editable workspace at #{path}: #{inspect(reason)}")
    end
  end

  def select_path!(workspace, opts, key) do
    configured = Keyword.get(workspace, key)
    command_line = Keyword.get(opts, key)

    if configured && command_line do
      Mix.raise("#{key} is declared in #{workspace[:path]} and on the command line; choose one")
    end

    command_line || configured
  end

  defp valid_path?(nil), do: true
  defp valid_path?(path), do: is_binary(path) and path != ""

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    error -> {:error, error}
  end
end
