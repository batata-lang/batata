defmodule Batata.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      beaver_dep(),
      kinda_dep(),
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  # Beaver and Kinda are pre-release; development uses local checkouts via
  # BEAVER_PATH / BEAVER_KINDA_PATH, falling back to Hex once released.
  defp beaver_dep do
    case System.get_env("BEAVER_PATH") do
      nil -> {:beaver, "~> 0.4.0"}
      path -> {:beaver, path: Path.expand(path)}
    end
  end

  defp kinda_dep do
    case System.get_env("BEAVER_KINDA_PATH") do
      nil -> {:kinda, "~> 0.11.0"}
      path -> {:kinda, path: Path.expand(path)}
    end
  end

  defp description() do
    "An Elixir-to-native compiler built on Beaver and the ex dialect."
  end
end
