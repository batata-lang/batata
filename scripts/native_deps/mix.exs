defmodule BatataNativeDeps.MixProject do
  use Mix.Project

  def project do
    [
      app: :batata_native_deps,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end
end
