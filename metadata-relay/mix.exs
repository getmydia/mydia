defmodule MetadataRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :metadata_relay,
      version: "0.2.2",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MetadataRelay.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      test: ["test"]
    ]
  end

  defp releases do
    [
      metadata_relay: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
