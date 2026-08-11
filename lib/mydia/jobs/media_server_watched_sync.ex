defmodule Mydia.Jobs.MediaServerWatchedSync do
  @moduledoc """
  Oban worker for syncing watched status between Mydia and media servers.

  Two modes:
  - **Individual**: Sync a specific server for a specific user.
    Args: `%{"config_id" => id, "user_id" => uid}`
  - **Scheduler**: Find all enabled servers with watched sync enabled
    and enqueue individual jobs for each server/user pair.
    Args: `%{"mode" => "all_enabled"}`
  """

  use Oban.Worker, queue: :integrations, max_attempts: 3

  alias Mydia.Accounts
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.WatchedSync
  alias Mydia.MediaServer.WatchedSync.Orchestrator
  alias Mydia.Settings

  require Logger

  defmodule Args do
    @moduledoc false
    defstruct [:mode, :config_id, :user_id]

    @type t :: %__MODULE__{
            mode: String.t() | nil,
            config_id: String.t() | nil,
            user_id: String.t() | nil
          }

    def parse(%{"mode" => "all_enabled"}) do
      %__MODULE__{mode: "all_enabled"}
    end

    def parse(%{"config_id" => config_id, "user_id" => user_id}) do
      %__MODULE__{config_id: config_id, user_id: user_id}
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "all_enabled"}}) do
    users = Accounts.list_users()

    Settings.list_media_server_configs()
    |> Enum.each(fn config ->
      case skip_reason(config) do
        nil -> Enum.each(users, &enqueue(config, &1))
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

    if config.enabled && watched_sync_enabled?(config) do
      direction = get_sync_direction(config)

      Logger.info("Starting watched sync (#{direction}) for #{config.name}, user #{user_id}")

      with {:ok, _adapter} <- WatchedSync.adapter_for(config) do
        {:ok, run} =
          Mydia.Sync.start_run(%{
            provider: to_string(config.type),
            provider_instance_id: config.id,
            user_id: user_id,
            direction: direction
          })

        case Orchestrator.sync(config, user_id, direction: direction) do
          {:ok, stats} ->
            Mydia.Sync.finish_run(run, :ok, stats, nil)
            # Only a successful sync updates the last-sync timestamp. It was
            # previously stamped unconditionally, so failures looked like successes.
            update_last_sync_timestamp(config)
            :ok

          {:error, reason} ->
            Mydia.Sync.finish_run(run, :error, %{}, describe_error(reason))
            {:error, reason}
        end
      end
    else
      # Reachable when a config is disabled between enqueue and execution.
      # Rare, but returning {:ok, :skipped} with no trace is the exact pattern
      # this change exists to remove, so it is recorded like any other skip.
      reason = skip_reason(config) || :sync_disabled

      Logger.debug("Skipping watched sync for #{config.name}: #{reason}")

      record_skip(config, reason, user_id)

      {:ok, :skipped}
    end
  end

  # A skip is a first-class recorded outcome, not an early return. Returning
  # :ok without a trace is what made this job look healthy for 335 consecutive
  # runs while doing nothing at all.
  defp skip_reason(%{enabled: false}), do: :server_disabled

  defp skip_reason(config) do
    cond do
      not watched_sync_enabled?(config) -> :sync_disabled
      match?({:error, _}, WatchedSync.adapter_for(config)) -> :unsupported_provider
      true -> nil
    end
  end

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

  defp enqueue(config, user) do
    %{"config_id" => config.id, "user_id" => user.id}
    |> __MODULE__.new()
    |> safe_insert()
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
