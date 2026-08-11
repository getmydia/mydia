defmodule Mydia.Jobs.MediaServerWatchedSync do
  @moduledoc """
  Oban worker for syncing watched status between Mydia and media servers.

  Two modes:
  - **Individual**: Sync a specific server for a specific user.
    Args: `%{"config_id" => id, "user_id" => uid, "link_id" => lid}`
  - **Scheduler**: Find all enabled servers with watched sync enabled
    and enqueue individual jobs for each linked user.
    Args: `%{"mode" => "all_enabled"}`
  """

  use Oban.Worker, queue: :integrations, max_attempts: 3

  alias Mydia.MediaServer.Error
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerUserLink
  alias Mydia.WatchSync
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
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_enabled"}}) do
    Settings.list_media_server_configs()
    |> Enum.each(fn config ->
      case skip_reason(config) do
        nil -> enqueue_linked_users(config)
        reason -> record_skip(config, reason)
      end
    end)

    :ok
  end

  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)
    config_id = args.config_id
    user_id = args.user_id
    config = Settings.get_media_server_config!(config_id)

    case apply_link_token(config, args.link_id, user_id) do
      {:ok, config} -> run_sync(config, user_id)
      {:error, reason} -> skip(config, reason, user_id)
    end
  end

  defp run_sync(config, user_id) do
    if config.enabled && watched_sync_enabled?(config) do
      direction = get_sync_direction(config)

      Logger.info("Starting watched sync (#{direction}) for #{config.name}, user #{user_id}")

      with {:ok, provider} <- provider_for(config) do
        # A failed run insert must not take the sync down with it. Bookkeeping is
        # there to explain what happened, so losing it degrades observability
        # rather than the feature.
        run = start_run(config, user_id, direction)

        case WatchSync.sync(
               provider,
               config,
               %{user_id: user_id, access_token: config.token},
               provider: to_string(config.type),
               direction: direction
             ) do
          {:ok, stats} ->
            finish_run(run, :ok, stats, nil)
            # Only a successful sync updates the last-sync timestamp. It was
            # previously stamped unconditionally, so failures looked like successes.
            update_last_sync_timestamp(config)
            :ok

          {:error, reason} ->
            finish_run(run, :error, %{}, describe_error(reason))
            {:error, reason}
        end
      end
    else
      # Reachable when a config is disabled between enqueue and execution.
      # Rare, but returning {:ok, :skipped} with no trace is the exact pattern
      # this change exists to remove, so it is recorded like any other skip.
      skip(config, skip_reason(config) || :sync_disabled, user_id)
    end
  end

  defp skip(config, reason, user_id) do
    Logger.debug("Skipping watched sync for #{config.name}: #{reason}")
    record_skip(config, reason, user_id)
    {:ok, :skipped}
  end

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

  defp enqueue_linked_users(config) do
    case Settings.list_media_server_user_links(config.id) |> Enum.filter(& &1.enabled) do
      [] ->
        record_skip(config, :no_user_mapping)

      links ->
        Enum.each(links, fn link -> enqueue(config, link) end)
    end
  end

  defp enqueue(config, link) do
    %{"config_id" => config.id, "user_id" => link.user_id, "link_id" => link.id}
    |> __MODULE__.new()
    |> safe_insert()
  end

  # Per-user Plex tokens live on the link. Without swapping them onto the
  # config, every synced user would still read and write the admin account.
  #
  # A job with no link_id predates per-user mapping (or is the single-user
  # fallback), where the config token is the right one. But a job that names a
  # link whose token cannot be resolved must NOT quietly fall back to the config
  # token: that would sync one user against another account's watch state, which
  # is exactly the merge bug links exist to prevent.
  #
  # The link must also belong to the user being synced. Resolving by link id
  # alone would let a malformed or stale job pair user A with user B's token,
  # reintroducing the same merge from the other direction.
  defp apply_link_token(config, nil, _user_id), do: {:ok, config}

  defp apply_link_token(config, link_id, user_id) do
    case Repo.get(MediaServerUserLink, link_id) do
      %MediaServerUserLink{user_id: ^user_id, access_token: token}
      when is_binary(token) and token != "" ->
        {:ok, %{config | token: token}}

      %MediaServerUserLink{user_id: other} when other != user_id ->
        {:error, :link_user_mismatch}

      _ ->
        {:error, :link_token_missing}
    end
  end

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
