defmodule Mydia.Jobs.MediaServerLinkSeed do
  @moduledoc """
  Seeds `media_server_user_links` for a media server from the accounts it
  reports, matching each account to a Mydia user by username.

  Links used to have no producer at all: the scheduler skipped every config with
  `:no_user_mapping` on every tick, forever, so scheduled sync had never run for
  anyone. This worker is the missing producer, running on a config save and from
  the scheduler's first look at a server that has never been seeded.

  It is not the only writer. The account mapping modal repoints and removes
  links by hand, so seeding runs with `only_new: true` and can add a Mydia user
  who has no link yet but never touch one who has. Rows here are the operator's;
  this worker only fills in the blanks.

  Seeding is a job rather than an inline call on the save path because it talks
  to the server. Jellyfin needs only the account list, since it has no per-user
  token to mint.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: 120, keys: [:config_id]]

  require Logger

  # Historical name, kept because `20260812170000_backfill_plex_links_seeded_at`
  # already wrote it on every Plex config that had links. It stamps any provider
  # this worker can seed; renaming it would need a second backfill to buy
  # nothing.
  @seeded_at_key "plex_links_seeded_at"

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.SeedResult
  alias Mydia.MediaServer.UserLinks
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Sync

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"config_id" => config_id}}) do
    config = Settings.get_media_server_config!(config_id)

    if seedable?(config) do
      seed(config, [])
    else
      :ok
    end
  rescue
    # The config was deleted between enqueue and execution. That is a terminal
    # state, not a failure worth three retries.
    Ecto.NoResultsError -> :ok
  end

  # A disabled, unconfigured, or unsupported server is a no-op rather than an
  # error. The scheduler enqueues this for any config missing links.
  #
  # Also requires watched sync itself to be on. `maybe_seed_user_links/1` fires
  # on every config save, including one that only wants library refresh and
  # never opted into watched-status sync. Without this check, seeding would
  # enumerate the server's accounts for a feature the operator never asked for.
  # Nothing is lost: the scheduler path only enqueues a seed once sync is on, and turning
  # sync on later is itself a config save that re-triggers
  # `maybe_seed_user_links/1`.
  #
  # Env/YAML servers (synthetic "runtime::" ids) are never seeded: the links
  # table has a foreign key to media_server_configs, so they cannot own rows.
  defp seedable?(%{type: type, enabled: true, token: token} = config)
       when type == :jellyfin and is_binary(token) and token != "" do
    not Settings.runtime_config?(config) and watched_sync_enabled?(config)
  end

  defp seedable?(_), do: false

  defp watched_sync_enabled?(config) do
    case config.connection_settings do
      %{} = settings -> Map.get(settings, "sync_watched") in [true, "true"]
      _ -> false
    end
  end

  defp seed(config, opts) do
    case UserLinks.discover(config, opts) do
      {:ok, %SeedResult{} = result} ->
        maybe_mark_seeded(config, result)
        record_outcome(config, result)

      # No stamp on failure: the server having a bad minute is not the operator
      # deciding anything, and the next save or scheduler tick should try again.
      {:error, reason} ->
        record_skip(config, :link_seeding_failed)
        {:error, describe(reason)}
    end
  end

  # Jellyfin mints nothing, so every pass that returns `{:ok, _}` is conclusive.
  defp maybe_mark_seeded(config, %SeedResult{}), do: mark_seeded(config)

  defp record_outcome(config, %SeedResult{linked: [_ | _] = links}) do
    Logger.info("Seeded #{length(links)} user link(s) for #{config.name}")
    enqueue_sync(config)
    :ok
  end

  # Deliberately enqueues nothing. Server mode with no links enqueues this
  # worker, and this worker enqueues server mode, so only a run that actually
  # produced links may re-enter that cycle.
  #
  # `already_mapped` is not a reason to re-enter it either: a pass that linked
  # nothing and merely left existing mappings alone would fan out to nothing and
  # enqueue this worker straight back. It is logged rather than recorded, because
  # the two cases share one skip reason and the log is what tells an operator
  # debugging a quiet server which of them they are looking at.
  defp record_outcome(config, %SeedResult{linked: [], already_mapped: kept}) do
    if kept != [] do
      Logger.info("Left #{length(kept)} existing mapping(s) alone on #{config.name}")
    end

    record_skip(config, :no_matching_users)
    :ok
  end

  # Records that this config has been through a seeding pass. The scheduler
  # reads it to tell a server nobody has ever seeded from one whose mappings the
  # operator removed, and re-seeds only the first. Without it, clearing every
  # mapping put them all back on the next tick, against a modal that promises
  # watched sync will skip the user until they are mapped again.
  #
  # Stamped on a pass that linked nothing as well, so a server whose accounts
  # match no Mydia username stops re-running its account listing on every tick.
  # `maybe_mark_seeded/2` decides which passes count.
  defp mark_seeded(config) do
    settings =
      Map.put(
        config.connection_settings || %{},
        @seeded_at_key,
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    case Settings.update_media_server_config(config, %{connection_settings: settings}) do
      {:ok, _config} ->
        :ok

      # Bookkeeping, so losing it costs a redundant seed rather than the run.
      {:error, reason} ->
        Logger.warning("Could not stamp link seeding for #{config.name}: #{inspect(reason)}")
        :ok
    end
  end

  defp enqueue_sync(config) do
    %{"mode" => "server", "config_id" => config.id}
    |> MediaServerWatchedSync.new()
    |> safe_insert()
  end

  # Oban is not started under `testing: :manual` (config/test.exs), so
  # Oban.insert/1 raises a RuntimeError when a job's own perform/1 tries to
  # enqueue another job during tests. `MediaServerWatchedSync.safe_insert/1`
  # establishes this fallback; mirrored here for the same reason.
  defp safe_insert(changeset) do
    try do
      Oban.insert(changeset)
    rescue
      RuntimeError -> Repo.insert(changeset)
    end
  end

  defp record_skip(config, reason) do
    Sync.record_skip(
      %{provider: to_string(config.type), provider_instance_id: config.id, user_id: nil},
      reason
    )
  end

  @doc """
  Whether a seeding pass has already completed for this config.

  `Mydia.Jobs.MediaServerWatchedSync` asks before seeding a server that has no
  mappings, because "never seeded" and "the operator removed them all" look
  identical from the links table alone and only the first should be filled in.
  """
  @spec seeded_before?(map()) :: boolean()
  def seeded_before?(%{connection_settings: %{} = settings}),
    do: is_binary(Map.get(settings, @seeded_at_key))

  def seeded_before?(_config), do: false

  # `only_new: true` is not passed here on purpose: `UserLinks.discover/2` forces
  # it and no argument can turn it off, so there is one place that decides it
  # rather than two that have to agree.
  defp describe(%Error{} = error), do: Error.message(error)
  defp describe(reason), do: inspect(reason)
end
