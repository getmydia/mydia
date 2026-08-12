defmodule Mydia.Jobs.PlexLinkSeed do
  @moduledoc """
  Seeds `media_server_user_links` for a Plex config from its Plex Home profiles.

  `Mydia.MediaServer.Plex.Home.seed_links/2` is the only code that creates those
  links, and it had no caller at all. Without links the watched-sync scheduler
  skipped every config with `:no_user_mapping` on every tick, forever, so
  scheduled sync had never run for anyone. This worker is the missing caller.

  Seeding makes 1 + N plex.tv round trips (list Home users, then one profile
  switch per matched user), which is why it is a job rather than an inline call
  on the save path.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: 120, keys: [:config_id]]

  require Logger

  alias Mydia.Jobs.MediaServerWatchedSync
  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Plex.Home
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Sync

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"config_id" => config_id} = args}) do
    config = Settings.get_media_server_config!(config_id)

    if seedable?(config) do
      seed(config, seed_opts(args))
    else
      :ok
    end
  rescue
    # The config was deleted between enqueue and execution. That is a terminal
    # state, not a failure worth three retries.
    Ecto.NoResultsError -> :ok
  end

  # A non-Plex or unconfigured server is a no-op rather than an error. The
  # scheduler enqueues this for any config missing links, and a Jellyfin server
  # with no Plex links is the expected state.
  defp seedable?(%{type: :plex, enabled: true, token: token})
       when is_binary(token) and token != "",
       do: true

  defp seedable?(_), do: false

  defp seed(config, opts) do
    case Home.seed_links(config, opts) do
      {:ok, [_ | _] = links} ->
        Logger.info("Seeded #{length(links)} Plex user link(s) for #{config.name}")
        enqueue_sync(config)
        :ok

      # Deliberately enqueues nothing. Server mode with no links enqueues this
      # worker, and this worker enqueues server mode, so only a run that
      # actually produced links may re-enter that cycle.
      {:ok, []} ->
        record_skip(config, :no_matching_users)
        :ok

      {:error, reason} ->
        record_skip(config, :link_seeding_failed)
        {:error, describe(reason)}
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

  # A test seam so Bypass can stand in for plex.tv. Production jobs never carry
  # it, and it is deliberately not read from application env, which would leak
  # across concurrent tests.
  defp seed_opts(%{"plex_tv_base" => base}) when is_binary(base), do: [plex_tv_base: base]
  defp seed_opts(_), do: []

  defp describe(%Error{} = error), do: Error.message(error)
  defp describe(reason), do: inspect(reason)
end
