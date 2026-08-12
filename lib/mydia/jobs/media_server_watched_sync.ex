defmodule Mydia.Jobs.MediaServerWatchedSync do
  @moduledoc """
  Oban worker for syncing watched status between Mydia and media servers.

  Two modes:
  - **Individual**: Sync a specific server for a specific user.
    Args: `%{"config_id" => id, "user_id" => uid, "link_id" => lid}`.
    `link_id` says which remote account the user is; a job without one is
    recorded as a skip rather than run against the server owner's account.
  - **Scheduler**: Find all enabled servers with watched sync enabled
    and enqueue individual jobs for each linked user.
    Args: `%{"mode" => "all_enabled"}`
  """

  use Oban.Worker, queue: :integrations, max_attempts: 3

  # Provider refusals that no retry can fix: the link is missing the identity
  # that provider's auth model needs. `Plex` wants a per-user token, `Jellyfin`
  # wants an account GUID.
  @misconfigured [:missing_user_token, :missing_remote_user_id]

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

    def parse(%{"config_id" => config_id, "user_id" => user_id} = args) do
      %__MODULE__{
        config_id: config_id,
        user_id: user_id,
        link_id: Map.get(args, "link_id")
      }
    end

    # Anything else, notably the empty map the Jobs page used to enqueue, runs
    # as the scheduler rather than crashing the worker to `discarded`.
    def parse(_args), do: %__MODULE__{mode: "all_enabled"}
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    case Args.parse(raw_args) do
      %Args{mode: "all_enabled"} -> perform_all_enabled()
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

  defp perform_individual(%Args{config_id: config_id, user_id: user_id} = args) do
    config = Settings.get_media_server_config!(config_id)

    case resolve_user_scope(config, args.link_id, user_id) do
      {:ok, scope} -> run_sync(config, scope)
      {:error, reason} -> skip(config, reason, user_id)
    end
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

        case WatchSync.sync(provider, config, scope,
               provider: to_string(config.type),
               direction: direction
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
      true -> nil
    end
  end

  defp provider_for(%{type: :plex}), do: {:ok, Plex}
  defp provider_for(%{type: :jellyfin}), do: {:ok, Jellyfin}
  defp provider_for(_), do: {:error, :unsupported_provider}

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

  @doc """
  Enqueues one individual sync for the user a link names.

  Public because the admin page's "Sync now" is the other producer of these
  jobs, and the three args have to agree: `user_id` and `link_id` are read off
  the same row here, so no caller can pair a user with someone else's identity
  by building the map itself.
  """
  @spec enqueue(map(), MediaServerUserLink.t()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(config, %MediaServerUserLink{} = link) do
    %{"config_id" => config.id, "user_id" => link.user_id, "link_id" => link.id}
    |> __MODULE__.new()
    |> safe_insert()
  end

  defp enqueue_linked_users(config) do
    case Settings.list_media_server_user_links(config.id) |> Enum.filter(& &1.enabled) do
      [] ->
        record_skip(config, :no_user_mapping)

      links ->
        Enum.each(links, fn link -> enqueue(config, link) end)
    end
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
  # read and write the server owner's watch state. Both producers name a link:
  # `enqueue/2` reads it from the scheduler's own list, and the admin page
  # resolves the pressing user's link before it enqueues anything.
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

  defp update_last_sync_timestamp(config) do
    current_settings = config.connection_settings || %{}
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    updated_settings = Map.put(current_settings, "last_watched_sync_at", now)

    Settings.update_media_server_config(config, %{connection_settings: updated_settings})
  end
end
