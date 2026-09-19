defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :typesafe_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "An Elixir client for TypeSafe's System One API (Jev).",
      docs: [main: "TypeSafe", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5 or ~> 0.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:plug, "~> 1.15", only: :test}
    ]
  end
end
