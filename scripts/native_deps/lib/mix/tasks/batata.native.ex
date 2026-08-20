defmodule Mix.Tasks.Batata.Native do
  use Mix.Task

  alias Batata.NativeDeps.Resolver
  alias Batata.NativeDeps.Runner

  @shortdoc "Sets up and runs Batata's pinned native dependencies"

  @setup_switches [
    llvm_config: :string,
    beaver_path: :string,
    kinda_path: :string
  ]

  @impl Mix.Task
  def run(["setup" | args]) do
    {opts, positional} = OptionParser.parse!(args, strict: @setup_switches)
    if positional != [], do: Mix.raise("unexpected setup arguments: #{inspect(positional)}")

    config = Resolver.setup!(opts)
    Mix.shell().info("Wrote #{Batata.NativeDeps.config_path()}")
    Mix.shell().info("Beaver: #{config[:beaver_path]}")
    Mix.shell().info("Kinda: #{config[:kinda_path]}")
    Mix.shell().info("LLVM: #{config[:llvm_config_path]}")
  end

  def run(["doctor"]), do: Runner.doctor!()

  def run(["verify"]) do
    Runner.verify!()
    Mix.shell().info("Native dependency receipt is valid")
  end

  def run(["compile" | args]), do: Runner.run_mix!(["compile" | args])
  def run(["test" | args]), do: Runner.run_mix!(["test" | args])
  def run(["run", "--" | args]) when args != [], do: Runner.run_mix!(args)

  def run(["exec", "--", command | args]) do
    executable = System.find_executable(command) || Mix.raise("executable not found: #{command}")
    Runner.run_command!(executable, args)
  end

  def run(_args) do
    Mix.raise("""
    usage:
      mix batata.native setup [--beaver-path PATH] [--kinda-path PATH] [--llvm-config PATH]
      mix batata.native doctor
      mix batata.native verify
      mix batata.native compile
      mix batata.native test [ARGS...]
      mix batata.native run -- TASK [ARGS...]
      mix batata.native exec -- COMMAND [ARGS...]
    """)
  end
end
