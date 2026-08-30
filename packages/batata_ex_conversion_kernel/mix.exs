defmodule BatataExConversionKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata_ex_conversion_kernel,
      version: "0.1.0-dev",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Batata Ex Conversion Kernel",
      description: "Batata-owned native Ex conversion kernel artifacts and bootstrap receipts",
      package: package()
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  defp deps do
    [
      batata_dep(),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp batata_dep do
    case System.get_env("BATATA_PATH") do
      nil -> {:batata, "~> 0.1.0"}
      path -> {:batata, path: Path.expand(path)}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/batata-lang/batata"},
      files: ~w(lib priv .formatter.exs mix.exs README.md)
    ]
  end
end
