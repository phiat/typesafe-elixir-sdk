defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/phiat/typesafe-elixir-sdk"

  def project do
    [
      app: :typesafe_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Unofficial Elixir client for TypeSafe's System One API (Jev): " <>
          "typed Noul, Choice and Score judgments over Req.",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url, "TypeSafe docs" => "https://docs.typesafe.ai/"}
      ],
      docs: [main: "TypeSafe", extras: ["README.md", "LICENSE"], source_ref: "v#{@version}"]
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
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
