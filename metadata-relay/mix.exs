defmodule MetadataRelay.MixProject do
  use Mix.Project

  def project do
    [
      app: :metadata_relay,
      version: "0.10.1",
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
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.15"},
      {:req, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.5"},
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.17"},
      {:error_tracker, "~> 0.7"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:corsica, "~> 2.0"}
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
