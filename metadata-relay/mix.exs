defmodule MetadataRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :metadata_relay,
      version: "0.14.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
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
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.8"},
      {:ecto, "~> 3.14"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.24"},
      {:error_tracker, "~> 0.9"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.28"},
      {:gen_smtp, "~> 1.3"},
      {:lazy_html, "~> 0.1", only: :test},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:corsica, "~> 2.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["test"],
      "assets.setup": [
        "cmd --cd assets npm ci",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["tailwind metadata_relay", "esbuild metadata_relay"],
      "assets.deploy": [
        "cmd --cd assets npm ci",
        "tailwind metadata_relay --minify",
        "esbuild metadata_relay --minify",
        "phx.digest"
      ]
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
