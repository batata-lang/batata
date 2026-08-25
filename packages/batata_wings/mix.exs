defmodule BatataWings.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata_wings,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Batata Wings",
      description: "A provenance-tracked Wings3D geometry kernel for Batata",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    [
      batata_dep(),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp batata_dep do
    case System.get_env("BATATA_PATH") do
      nil -> {:batata, "~> 0.1.0"}
      path -> {:batata, path: Path.expand(path)}
    end
  end

  defp docs do
    [
      main: "Batata.Wings",
      source_url: "https://github.com/batata-lang/batata",
      extras: ["README.md", "LICENSE.wings"]
    ]
  end

  defp package do
    [
      licenses: ["Wings3D"],
      links: %{
        "GitHub" => "https://github.com/batata-lang/batata",
        "Wings3D upstream" => "https://github.com/dgud/wings"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE.wings)
    ]
  end
end
