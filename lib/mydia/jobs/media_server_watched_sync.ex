defmodule Mydia.Jobs.MediaServerWatchedSync do
  @moduledoc """
  Oban worker for syncing watched status between Mydia and media servers.

  Three modes:
  - **Individual**: Sync a specific server for a specific user.
    Args: `%{"config_id" => id, "user_id" => uid, "link_id" => lid}`.
    `link_id` says which remote account the user is; a job without one is
    recorded as a skip rather than run against the server owner's account.
  - **Server**: Fan out to an individual job for every link on one server,
    seeding links first when a server has none and has never been seeded. This
    is what the "Sync Now" button triggers, and what
    `Mydia.Jobs.MediaServerLinkSeed` enqueues after a successful seed. Fanning
    out per link is also what keeps a manual sync off the server owner's
    account: every job it produces names a link, so none of them can fall
    through to the config's own token.
    Args: `%{"mode" => "server", "config_id" => id}`
  - **Scheduler**: Find every enabled server with watched sync enabled and
    fan out the same way, one server at a time.
    Args: `%{"mode" => "all_enabled"}`

  Unrecognised args parse as the scheduler rather than crashing the worker.
  """

  use Oban.Worker, queue: :integrations, max_attempts: 3

  # Provider refusals that no retry can fix: the link is missing the identity
  # that provider's auth model needs. `Plex` wants a per-user token, `Jellyfin`
  # wants an account GUID.
  @misconfigured [:missing_user_token, :missing_remote_user_id]

  # A mapping crawl is the expensive call, so it does not run on every tick. But
  # the engine only crawls an instance that has no mappings at all, which means
  # it runs exactly once in an instance's life: media added later is never
  # mapped, and a fix to id matching is never picked up. Re-crawling on an
  # interval is what makes both self-healing.
  @mapping_refresh_interval_seconds 24 * 60 * 60

  alias Mydia.MediaServer.Error
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerUserLink
  alias Mydia.WatchSync
  alias Mydia.WatchSync.Providers.Jellyfin
  alias Mydia.WatchSync.Providers.Plex

  require Logger

  defmodule Args do
    @moduledoc false
    defstruct [:mode, :config_id, :user_id, :link_id]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            config_id: String.t() | nil,
            user_id: String.t() | nil,
            link_id: String.t() | nil
          }

    def parse(%{"mode" => "all_enabled"}) do
      %__MODULE__{mode: "all_enabled"}
    end

    def parse(%{"mode" => "server", "config_id" => config_id}) do
      %__MODULE__{mode: "server", config_id: config_id}
    end

    def parse(%{"config_id" => config_id, "user_id" => user_id} = args) do
      %__MODULE__{
        config_id: config_id,
        user_id: user_id,
        link_id: Map.get(args, "link_id")
      }
    end

    # Anything else, an empty map included, runs as the scheduler rather than
    # crashing the worker to `discarded`. Args this worker cannot read are a
    # reason to do the scheduled thing, not to burn three attempts.
    def parse(_args), do: %__MODULE__{mode: "all_enabled"}
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    case Args.parse(raw_args) do
      %Args{mode: "all_enabled"} -> perform_all_enabled()
      %Args{mode: "server"} = args -> perform_server(args)
      %Args{} = args -> perform_individual(args)
    end
  end

  defp perform_all_enabled do
    Settings.list_media_server_configs()
    |> Enum.each(fn config ->
      case skip_reason(config) do
        nil -> enqueue_linked_users(config)
        reason -> record_skip(config, reason)
      end
    end)

    :ok
  end

  # Syncs one server across every linked user. This is what the "Sync Now"
  # button and a successful link seed both trigger, so manual and scheduled
  # runs share one fan-out rather than drifting apart.
  #
  # It is also why "Sync now" no longer needs to resolve the pressing user's
  # own link: this fans out to every linked user on the server, and each job it
  # produces carries a link id, so none of them can reach the config's token.
  defp perform_server(%Args{config_id: config_id}) do
    config = Settings.get_media_server_config!(config_id)

    case skip_reason(config) do
      nil -> enqueue_linked_users(config)
      reason -> record_skip(config, reason)
    end

    :ok
  rescue
    # Deleting a media server while its jobs are still queued is ordinary
    # operator behaviour, and a deleted config is a terminal state rather than a
    # failure worth three retries. Mirrors Mydia.Jobs.MediaServerLinkSeed.
    Ecto.NoResultsError -> :ok
  end

  defp perform_individual(%Args{config_id: config_id, user_id: user_id} = args) do
    config = Settings.get_media_server_config!(config_id)

    case resolve_user_scope(config, args.link_id, user_id) do
      {:ok, scope} -> run_sync(config, scope)
      {:error, reason} -> skip(config, reason, user_id)
    end
  rescue
    # Same window, reached more often now that server mode fans these out.
    Ecto.NoResultsError -> :ok
  end

  defp run_sync(config, scope) do
    if config.enabled && watched_sync_enabled?(config) do
      direction = get_sync_direction(config)

      Logger.info(
        "Starting watched sync (#{direction}) for #{config.name}, user #{scope.user_id}"
      )

      with {:ok, provider} <- provider_for(config) do
        # A failed run insert must not take the sync down with it. Bookkeeping is
        # there to explain what happened, so losing it degrades observability
        # rather than the feature.
        run = start_run(config, scope.user_id, direction)
        refresh = refresh_mode(config)

        # Rebound deliberately: the claim writes connection_settings, and the
        # later update_last_sync_timestamp/1 merges into whatever config it is
        # handed. Passing the stale struct would drop the stamp we just wrote.
        config = claim_mapping_refresh(config, refresh)

        case WatchSync.sync(provider, config, scope,
               provider: to_string(config.type),
               direction: direction,
               refresh_mappings: refresh
             ) do
          {:ok, stats} ->
            finish_run(run, :ok, stats, nil)
            # Only a successful sync updates the last-sync timestamp. It was
            # previously stamped unconditionally, so failures looked like successes.
            update_last_sync_timestamp(config)
            :ok

          # A missing credential is a permanent misconfiguration, not a bad
          # minute on the network. Returned as an error it burned all three
          # Oban attempts and landed the job in `discarded`, where nothing in
          # the UI could say why. Recorded as a skip it reads like every other
          # credential problem on the page, and the operator gets told which
          # mapping to fix.
          {:error, reason} when reason in @misconfigured ->
            skip(config, reason, scope.user_id, run)

          {:error, reason} ->
            finish_run(run, :error, %{}, describe_error(reason))
            {:error, reason}
        end
      end
    else
      # Reachable when a config is disabled between enqueue and execution.
      # Rare, but returning {:ok, :skipped} with no trace is the exact pattern
      # this change exists to remove, so it is recorded like any other skip.
      skip(config, skip_reason(config) || :sync_disabled, scope.user_id)
    end
  end

  defp skip(config, reason, user_id, run \\ nil) do
    Logger.debug("Skipping watched sync for #{config.name}: #{reason}")
    write_skip(run, config, reason, user_id)
    {:ok, :skipped}
  end

  # A run already open for this attempt becomes the skip. Inserting a second row
  # instead would leave an unfinished `:ok` run next to it, and the admin page
  # reads whichever landed last.
  defp write_skip(nil, config, reason, user_id), do: record_skip(config, reason, user_id)
  defp write_skip(run, _config, reason, _user_id), do: Mydia.Sync.skip_run(run, reason)

  # Returns the run, or nil when the insert failed. `finish_run/4` tolerates nil
  # so a bookkeeping failure degrades observability instead of failing the sync.
  defp start_run(config, user_id, direction) do
    case Mydia.Sync.start_run(%{
           provider: to_string(config.type),
           provider_instance_id: config.id,
           user_id: user_id,
           direction: direction
         }) do
      {:ok, run} ->
        run

      {:error, reason} ->
        Logger.warning("Could not record sync run start: #{inspect(reason)}")
        nil
    end
  end

  defp finish_run(nil, _status, _counts, _error), do: :ok

  defp finish_run(run, status, counts, error),
    do: Mydia.Sync.finish_run(run, status, counts, error)

  # A skip is a first-class recorded outcome, not an early return. Returning
  # :ok without a trace is what made this job look healthy for 335 consecutive
  # runs while doing nothing at all.
  defp skip_reason(%{enabled: false}), do: :server_disabled

  defp skip_reason(config) do
    cond do
      not watched_sync_enabled?(config) -> :sync_disabled
      match?({:error, _}, provider_for(config)) -> :unsupported_provider
      not has_token?(config) -> :no_token
      true -> nil
    end
  end

  defp provider_for(%{type: :plex}), do: {:ok, Plex}
  defp provider_for(%{type: :jellyfin}), do: {:ok, Jellyfin}
  defp provider_for(_), do: {:error, :unsupported_provider}

  # token isn't validate_required on MediaServerConfig. Without this, a Plex
  # config saved with sync on but a blank token would pass skip_reason/1,
  # record :seeding_links on every tick, and enqueue a seed job that can never
  # produce a link (MediaServerLinkSeed.seedable?/1 also requires a token), which is a
  # job reporting healthy while doing nothing forever.
  defp has_token?(%{token: token}), do: is_binary(token) and token != ""

  defp record_skip(config, reason, user_id \\ nil) do
    Mydia.Sync.record_skip(
      %{
        provider: to_string(config.type),
        provider_instance_id: config.id,
        user_id: user_id
      },
      reason
    )
  end

  # Enqueues one individual sync for the user a link names. Every producer of a
  # per-user job goes through here, and the match on `%MediaServerUserLink{}` is
  # what makes that worth something: `user_id` and `link_id` are read off the
  # same row, so no caller can pair a user with someone else's identity by
  # building the args map itself.
  @spec enqueue(map(), MediaServerUserLink.t()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  defp enqueue(config, %MediaServerUserLink{} = link) do
    %{"config_id" => config.id, "user_id" => link.user_id, "link_id" => link.id}
    |> __MODULE__.new()
    |> safe_insert()
  end

  defp enqueue_linked_users(config) do
    case Settings.list_media_server_user_links(config.id) do
      [] -> handle_no_links(config)
      links -> Enum.each(links, fn link -> enqueue(config, link) end)
    end
  end

  # Seeding is a first run, not a repair. Links are the operator's now: the
  # account mapping modal creates, repoints and removes them, promising that
  # watched sync will skip a user until they are mapped again. So a server that
  # has already been through a seeding pass and now has nothing mapped is a
  # decision, not a gap, and re-seeding it would put back the very rows the
  # operator cleared. Only a server nobody has ever seeded is filled in
  # automatically.
  #
  # This also stops :seeding_links being re-recorded on every tick. A seeding
  # pass that matched no account stamps the config all the same, so its
  # :no_matching_users verdict is no longer buried under a newer "Linking
  # accounts" row that describes a state already dead.
  defp handle_no_links(config) do
    if Mydia.Jobs.MediaServerLinkSeed.seeded_before?(config) do
      record_skip(config, :no_user_mapping)
    else
      enqueue_seed(config)
      record_skip(config, :seeding_links)
    end
  end

  defp enqueue_seed(config) do
    %{"config_id" => config.id}
    |> Mydia.Jobs.MediaServerLinkSeed.new()
    |> safe_insert()
  end

  # A link must say *which* remote account a user is, or the sync would run
  # against the admin account and merge two people's watch history. That
  # identity is a per-user token on Plex and a user GUID on Jellyfin, so the
  # scope carries whichever the link holds and each provider reads the field
  # its auth model uses. Only a link holding neither is refused.
  #
  # A link's access_token is carried as-is, nil included: it must never fall
  # back to the server's own config.token, because that IS the admin account
  # for token-based providers. A link with a GUID but no token is a valid
  # Jellyfin-shaped scope and a refused Plex-shaped one; each provider decides
  # which fields it needs, not this function.
  #
  # The link must also belong to the user being synced, so a stale or malformed
  # job cannot pair user A with user B's identity.
  #
  # A job carrying no link at all is refused rather than falling back to the
  # server's own config.token. That fallback made whoever pressed "Sync now"
  # read and write the server owner's watch state. Nothing produces that shape
  # any more: `enqueue/2` is the only producer of a per-user job and it reads
  # the user and the link off one row, while "Sync now" enqueues server mode and
  # lets that fan-out name the links.
  defp resolve_user_scope(_config, nil, _user_id), do: {:error, :link_not_found}

  defp resolve_user_scope(_config, link_id, user_id) do
    case Repo.get(MediaServerUserLink, link_id) do
      %MediaServerUserLink{user_id: ^user_id} = link -> scope_from_link(link, user_id)
      %MediaServerUserLink{} -> {:error, :link_user_mismatch}
      nil -> {:error, :link_not_found}
    end
  end

  defp scope_from_link(link, user_id) do
    token = presence(link.access_token)
    remote_user_id = presence(link.remote_user_id)

    if is_nil(token) and is_nil(remote_user_id) do
      {:error, :link_identity_missing}
    else
      {:ok, %{user_id: user_id, remote_user_id: remote_user_id, access_token: token}}
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  defp describe_error(%Error{} = error), do: Error.message(error)
  defp describe_error(reason), do: inspect(reason)

  defp watched_sync_enabled?(config) do
    get_in_connection_settings(config, "sync_watched") in [true, "true"]
  end

  defp get_sync_direction(config) do
    case get_in_connection_settings(config, "sync_watched_direction") do
      "import" -> :import
      "export" -> :export
      _ -> :bidirectional
    end
  end

  defp get_in_connection_settings(config, key) do
    case config.connection_settings do
      %{} = settings -> Map.get(settings, key)
      _ -> nil
    end
  end

  defp safe_insert(changeset) do
    try do
      Oban.insert(changeset)
    rescue
      RuntimeError ->
        Mydia.Repo.insert(changeset)
    end
  end

  # `:force` when no crawl has ever been recorded, when the stamp cannot be
  # read, or when it has aged past the interval.
  defp refresh_mode(config) do
    with value when is_binary(value) <-
           get_in_connection_settings(config, "last_mapping_refresh_at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      if DateTime.diff(DateTime.utc_now(), at, :second) >= @mapping_refresh_interval_seconds,
        do: :force,
        else: :auto
    else
      _ -> :force
    end
  end

  # Stamped before the sync runs, not after it succeeds. A server with several
  # linked users fans out one job per user on the same tick, and stamping on
  # success would have every one of them crawl the whole library. Claiming it up
  # front means the first job crawls and the rest read a fresh stamp.
  #
  # The cost is that a run failing after a forced crawl waits for the next
  # interval instead of retrying immediately. That is acceptable: the crawl is
  # idempotent upserts, so whatever it wrote persists.
  defp claim_mapping_refresh(config, :auto), do: config

  defp claim_mapping_refresh(config, :force) do
    case put_connection_setting(config, "last_mapping_refresh_at", iso_now()) do
      {:ok, updated} -> updated
      {:error, _reason} -> config
    end
  end

  defp update_last_sync_timestamp(config) do
    put_connection_setting(config, "last_watched_sync_at", iso_now())
  end

  defp put_connection_setting(config, key, value) do
    settings = Map.put(config.connection_settings || %{}, key, value)
    Settings.update_media_server_config(config, %{connection_settings: settings})
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
