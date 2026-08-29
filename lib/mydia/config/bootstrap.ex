defmodule Mydia.Config.Bootstrap do
  @moduledoc """
  Merges the database configuration layer into the cached runtime config, once,
  at boot.

  `Mydia.Application.start/2` has to load configuration before the supervision
  tree exists, because `children/0` reads from it. At that point `Mydia.Repo` is
  not running and, on a fresh install, `config_settings` has not been migrated,
  so that first load deliberately asks for `sources: [:yaml, :env]` only.

  This child closes the gap. It sits after `Ecto.Migrator`, so the table is
  guaranteed to exist, and calls `Mydia.Config.Loader.reload/1` to re-merge all
  four layers into `Application.get_env(:mydia, :runtime_config)`. Every child
  after it, and every request and job, sees database-backed settings.

  ## Why position is load-bearing

  Above `Ecto.Migrator` this reads a table that may not exist. Below a consumer
  of a database-backed setting, that consumer boots with file and environment
  values only.

  Before this child existed there was no second merge at all. The pre-supervisor
  load rescued Ecto's "repo not started" error into an empty database layer, and
  the only `Loader.reload/0` callers were three save handlers, so a setting saved
  in the admin UI worked until the next restart and then silently reverted. The
  FlareSolverr row is where that surfaced: its badge read the `ConfigSetting`
  rows directly and said Enabled while the client read the cached config and
  answered "FlareSolverr is disabled".

  Work happens synchronously in `init/1`, which then returns `:ignore`, so no
  process lingers. This mirrors `Mydia.Release.MigrationBackup`.

  ## Failure policy

  A failed merge logs at `:error` and startup continues with the phase-one
  config. Refusing to boot would lock an operator out of an instance over a
  configuration they can only repair from inside it.
  """

  use GenServer

  require Logger

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # `skip: true` is how the test environment opts out. The merge queries
    # config_settings from the supervisor's own process, which owns no SQL
    # Sandbox connection, so running it under `mix test` raises
    # DBConnection.OwnershipError before a single test starts. That error is
    # deliberately not in load_database_config/1's rescue list, so it would
    # take the whole suite down at boot. Tests call run/1 directly instead.
    unless Keyword.get(opts, :skip, false) do
      run(Keyword.delete(opts, :skip))
    end

    :ignore
  end

  @doc """
  Re-merges every configuration layer into the cached runtime config.

  Never raises. Returns `{:error, reason}` when the merged configuration fails
  schema validation, in which case `Mydia.Config.Loader.reload/1` has left the
  previously cached config untouched.
  """
  @spec run(keyword()) :: {:ok, Mydia.Config.Schema.t()} | {:error, term()}
  def run(opts \\ []) do
    case Mydia.Config.Loader.reload(opts) do
      {:ok, config} ->
        Logger.info("Merged the database configuration layer into the runtime config")
        {:ok, config}

      {:error, reason} ->
        Logger.error(
          "Failed to merge the database configuration layer at startup: #{inspect(reason)}. " <>
            "Settings saved in the admin UI will NOT take effect until the merged " <>
            "configuration is valid. Continuing with file and environment configuration only."
        )

        {:error, reason}
    end
  end
end
