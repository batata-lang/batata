defmodule BatataJason.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata_jason,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Batata Jason",
      description: "Fail-closed Jason compatibility evidence for Batata",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      package_dep(:batata, "BATATA_PATH", "~> 0.1.0"),
      package_dep(:batata_probe, "BATATA_PROBE_PATH", "~> 0.1.0"),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package_dep(name, environment, requirement) do
    case System.get_env(environment) do
      nil -> {name, requirement}
      path -> {name, path: Path.expand(path)}
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp docs do
    [
      main: "Batata.Jason.Probe",
      source_url: "https://github.com/batata-lang/batata",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/batata-lang/batata",
        "Jason upstream" => "https://github.com/michalmuskala/jason"
      },
      files: ~w(lib priv .formatter.exs mix.exs README.md)
    ]
  end
end
