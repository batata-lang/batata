defmodule Mix.Tasks.Batata.CompilerKernel.Release do
  @shortdoc "Builds an auditable Stage 1/2 native compiler-kernel release"

  @moduledoc """
  Builds a callback-free compiler-kernel release for the current host.

      mix batata.compiler_kernel.release \
        --output _build/compiler-kernel-release \
        --compiler-revision "$BATATA_REVISION" \
        --beaver-revision "$BEAVER_REVISION"

  The target triple defaults to the Erlang VM system architecture. CPU and
  feature values describe artifact compatibility and default to `generic` and
  an empty list.
  """

  use Mix.Task

  alias Batata.CompilerKernel.Release
  alias Beaver.MLIR

  @switches [
    output: :string,
    compiler_revision: :string,
    beaver_revision: :string,
    target_triple: :string,
    target_cpu: :string,
    target_features: :string,
    profile_sizes: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid compiler-kernel release arguments: #{inspect(positional ++ invalid)}")
    end

    Mix.Task.run("app.start")
    ctx = MLIR.Context.create()
    MLIR.Context.allow_unregistered_dialects(ctx)

    try do
      output =
        Release.build!(Keyword.get(opts, :output, "_build/compiler-kernel-release"), ctx,
          compiler_revision: required!(opts, :compiler_revision),
          beaver_revision: required!(opts, :beaver_revision),
          target: target(opts),
          profile_sizes: profile_sizes(opts)
        )

      Mix.shell().info("compiler-kernel release: #{output.index_path}")
      Mix.shell().info("production identity: #{output.index["production_kernel_identity"]}")
    after
      MLIR.Context.destroy(ctx)
    end
  end

  defp target(opts) do
    features =
      opts
      |> Keyword.get(:target_features, "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "triple" =>
        Keyword.get_lazy(opts, :target_triple, fn ->
          :erlang.system_info(:system_architecture) |> List.to_string()
        end),
      "cpu" => Keyword.get(opts, :target_cpu, "generic"),
      "features" => features
    }
  end

  defp profile_sizes(opts) do
    opts
    |> Keyword.get(:profile_sizes, "32,256,2048")
    |> String.split(",", trim: true)
    |> Enum.map(fn value ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> Mix.raise("--profile-sizes must contain positive integers")
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp required!(opts, key), do: Keyword.get(opts, key) || Mix.raise("--#{key} is required")
end
