# Build-time quality helper for mix_unused. Defined here (not under lib/) so it
# ships nowhere, is not itself dead-code analysed, and is always present when
# mix.exs is evaluated - including the Docker `mix deps.get --only prod` layer,
# which copies only mix.exs/mix.lock.
defmodule MydiaQuality do
  @moduledoc false

  @doc """
  True when `{module, fun, arity}` is a behaviour callback implemented by
  `module` - that is, `module` declares `@behaviour B` and `{fun, arity}` is
  one of `B`'s callbacks.

  Behaviour callbacks are dispatched by the framework that owns the behaviour
  (Guardian, Plug, telemetry, the app's own `@behaviour`s), so static export
  analysis cannot see the call site and flags them as unused. This predicate is
  a rule about tool blindness: it auto-covers every current and future callback
  implementation rather than enumerating individual findings.
  """
  @spec behaviour_callback?({module(), atom(), arity()}) :: boolean()
  def behaviour_callback?({module, fun, arity}) do
    module
    |> implemented_behaviours()
    |> Enum.any?(&callback?(&1, fun, arity))
  end

  defp implemented_behaviours(module) do
    if Code.ensure_loaded?(module) do
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
    else
      []
    end
  rescue
    _ -> []
  end

  defp callback?(behaviour, fun, arity) do
    Code.ensure_loaded?(behaviour) and
      function_exported?(behaviour, :behaviour_info, 1) and
      {fun, arity} in behaviour.behaviour_info(:callbacks)
  rescue
    _ -> false
  end
end

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
      compilers: compilers(),
      unused: [ignore: unused_ignore()],
      listeners: [Phoenix.CodeReloader],
      # Enforce warnings as errors to maintain code quality
      warnings_as_errors: Mix.env() != :prod,
      # Disable coverage threshold for now - will improve coverage later
      test_coverage: [summary: false]
    ]
  end

  # The mix_unused `:unused` compiler adds tracing overhead and prints a large
  # advisory report, so it only runs when UNUSED_CHECK=true (set by the
  # dead-code CI step). Normal dev/CI compiles are unaffected. It is gated to
  # dev/test because mix_unused is a dev/test-only dependency, and prepended
  # because that is the order under which it actually emits its analysis in
  # this version (appending it after Mix.compilers/0 yields no report).
  defp compilers do
    # `:plugins` builds the bundled WASM guests under plugins/*/ into
    # priv/plugins/ during mix compile (see Mix.Tasks.Compile.Plugins). It is
    # APPENDED, not prepended: the compiler task module lives in lib/ and is only
    # loadable after the `:elixir` compiler has run, so a fresh build can't find
    # `compile.plugins` if it runs first. Appending also still places the build
    # inside `mix compile`, so the artifact exists before `mix release` bundles
    # priv/. Unlike `:unused` (which must wrap elixir, hence prepended) `:plugins`
    # is independent. It runs on every compile in every env, including the
    # test-env --warnings-as-errors compile.
    base = [:phoenix_live_view] ++ Mix.compilers() ++ [:plugins]

    if System.get_env("UNUSED_CHECK") == "true" and Mix.env() in [:dev, :test] do
      [:unused | base]
    else
      base
    end
  end

  # Patterns excluded from mix_unused's unused-export analysis.
  #
  # Every entry here is a RULE describing a place static export analysis is
  # structurally blind (dynamic dispatch, macro-generated references, framework
  # callbacks) - never a list of specific dead functions we want to keep. A
  # rule auto-covers future code; a finding-list is grandfathering. Real dead
  # code is deleted, not listed here.
  #
  # Module regexes match against `inspect(module)`, e.g. "Mydia.Repo.Migrations.Foo".
  defp unused_ignore do
    [
      # Ecto migration callbacks (change/0, up/0, down/0) run by the migrator
      {~r/^Mydia\.Repo\.Migrations\./, :_, :_},
      # Generated reflection/introspection helpers (__absinthe_*__, __schema__, ...)
      {:_, ~r/^__/, :_},
      # Absinthe schema + resolvers referenced inside `field`/`resolve` macros
      {~r/^MydiaWeb\.Schema\./, :_, :_},
      # Phoenix Router generated route helpers and pipelines
      {~r/^MydiaWeb\.Router/, :_, :_},
      # Plug callbacks invoked by the Plug pipeline
      {:_, :init, 1},
      {:_, :call, 2},
      # Phoenix controller actions: dispatched by Phoenix.Controller's action
      # plug via apply(controller, action, [conn, params]) - the router names
      # the action as an atom, so the call site is invisible to static analysis.
      {~r/Controller$/, :_, 2},
      # `use MydiaWeb, :live_view | :controller | :html | ...` entrypoints,
      # invoked as MydiaWeb.<which>() by the using macro.
      {MydiaWeb, :_, 0},
      # OTP dispatch: supervisors call child_spec/1, which calls start_link/1
      {:_, :child_spec, 1},
      {:_, :start_link, 1},
      # Behaviour callbacks dispatched by the owning framework (Guardian, Plug,
      # telemetry, the app's own @behaviours). Predicate, not a name list, so it
      # auto-covers every current and future implementation.
      &MydiaQuality.behaviour_callback?/1
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Mydia.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh]
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
      {:phoenix_live_view, "~> 1.2.0"},
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
      {:finch, "~> 0.22"},
      {:req, "~> 0.6"},
      # WebSocket client for the Flutter dev-server proxy (PlayerDevSocket)
      {:websockex, "~> 0.5"},

      # WASM plugin runtime (wasmtime via Rustler NIF) + pooling
      {:wasmex, "~> 0.14"},
      {:nimble_pool, "~> 1.1"},

      # Utilities
      {:timex, "~> 3.7"},
      {:yaml_elixir, "~> 2.9"},
      {:ymlr, "~> 5.1"},
      {:sweet_xml, "~> 0.7"},
      {:floki, "~> 0.36"},
      {:nimble_parsec, "~> 1.4"},
      {:eqrcode, "~> 0.2.1"},
      {:earmark, "~> 1.4"},
      {:file_system, "~> 1.0", only: [:dev, :test]},

      # Telemetry & Monitoring
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:error_tracker, "~> 0.5"},
      # Vendor-neutral exception tracker; captures genuine exceptions/exits/throws
      # (Phoenix, Bandit, Oban, OTP crashes) and feeds Mydia.CrashReporter.TowerReporter.
      {:tower, "~> 0.8"},

      # Core
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # CORS support for cross-origin API requests (standalone player)
      {:corsica, "~> 2.1"},

      # Rustler for Libp2p NIF (native crate is on rustler 0.37.2; wasmex needs ~> 0.37.1)
      {:rustler, "~> 0.37", runtime: false},

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
      {:mix_unused, "~> 0.4", only: [:dev, :test], runtime: false}
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
        "test"
      ]
    ]
  end
end
