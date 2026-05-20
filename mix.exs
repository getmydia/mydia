defmodule Mydia.MixProject do
  use Mix.Project

  def project do
    [
      app: :mydia,
      version: version(),
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      licenses: ["AGPL-3.0-or-later"],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # Enforce warnings as errors to maintain code quality
      warnings_as_errors: Mix.env() != :prod,
      # Disable coverage threshold for now - will improve coverage later
      test_coverage: [summary: false],
      # Dialyzer configuration for strict type checking
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [
          :error_handling,
          :underspecs,
          :unknown,
          :extra_return,
          :missing_return
        ],
        plt_local_path: ".dialyzer"
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Mydia.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  defp version do
    case System.get_env("BUILD_VERSION") do
      nil -> "0.0.0-dev"
      "" -> "0.0.0-dev"
      v -> v
    end
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Phoenix Framework
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # Background Jobs
      {:oban, "~> 2.17"},
      {:crontab, "~> 1.1"},

      # Authentication (will be configured in task-5)
      {:ueberauth, "~> 0.10"},
      {:ueberauth_oidcc, "~> 0.4"},
      {:guardian, "~> 2.3"},
      # Password hashing for users
      {:bcrypt_elixir, "~> 3.0"},
      # Password hashing for API keys
      {:argon2_elixir, "~> 4.0"},

      # HTTP Clients
      {:finch, "~> 0.16"},
      {:req, "~> 0.4"},
      # WebSocket client for relay connections
      {:websockex, "~> 0.4.3"},

      # Utilities
      {:timex, "~> 3.7"},
      {:yaml_elixir, "~> 2.9"},
      {:ymlr, "~> 5.1"},
      {:luerl, "~> 1.2"},
      {:sweet_xml, "~> 0.7"},
      {:floki, "~> 0.36"},
      {:nimble_parsec, "~> 1.4"},
      {:eqrcode, "~> 0.2.1"},
      {:file_system, "~> 1.0", only: [:dev, :test]},

      # Telemetry & Monitoring
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:error_tracker, "~> 0.5"},
      # Logger backends were extracted from core Elixir in 1.15; required for
      # Mydia.CrashReporter.LoggerBackend to be installed as a :gen_event handler.
      {:logger_backends, "~> 1.0"},

      # Core
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # CORS support for cross-origin API requests (standalone player)
      {:corsica, "~> 2.1"},

      # Rustler for Libp2p NIF
      {:rustler, "~> 0.34.0", runtime: false},

      # GraphQL
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"},
      {:dataloader, "~> 2.0"},
      {:absinthe_relay, "~> 1.5"},

      # Development & Testing
      {:ex_machina, "~> 2.8", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind mydia", "esbuild mydia"],
      "assets.deploy": [
        "tailwind mydia --minify",
        "esbuild mydia --minify",
        "phx.digest"
      ],
      precommit: [
        "compile",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        # dialyzer temporarily excluded from precommit:
        # dialyxir 1.4.6 crashes on OTP 28's :exact_compare warning type.
        # Re-enable once dialyxir is updated: "dialyzer",
        "test"
      ]
    ]
  end
end
