defmodule BatataWingsGodot.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata_wings_godot,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Batata Wings Godot",
      description: "Materialize Batata Wings meshes through the closed Godot ArrayMesh ABI",
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
      package_dep(:batata_godot, "BATATA_GODOT_PATH", "~> 0.1.0"),
      package_dep(:batata_wings, "BATATA_WINGS_PATH", "~> 0.1.0"),
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

  defp docs do
    [
      main: "Batata.Wings.Godot",
      source_url: "https://github.com/batata-lang/batata",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/batata-lang/batata"},
      files: ~w(lib .formatter.exs mix.exs README.md)
    ]
  end
end
