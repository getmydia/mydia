defmodule Mydia.Jobs.AiringEpisodeRefresh do
  @moduledoc """
  Re-reads the seasons of airing shows whose episodes still carry placeholder
  metadata, between weekly `Mydia.Jobs.MetadataRefresh` passes.

  `Mydia.Media.AiringRefresh.due_seasons/2` picks the seasons and
  `Mydia.Media.refresh_seasons/3` re-reads them. Two crontab entries drive it,
  and the scope comes from the job args so the startup snooze can never move a
  run into the wrong tier:

    * `"all"` just after the UTC date turns over re-reads every due season.
    * `"hot"` three more times a day re-reads only seasons with an episode
      airing within a day of today.

  How fast a replaced title lands also depends on the relay, which caches
  settling season and episode responses for six hours (see
  `MetadataRelay.Cache.Settling`).
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger

  alias Mydia.Jobs.PassFailures
  alias Mydia.Media
  alias Mydia.Media.AiringRefresh

  @job_name "airing_episode_refresh"

  # Spread installs hitting the shared relay at the same crontab minute.
  # Snoozing releases the queue slot, and Oban raises max_attempts so the
  # jitter does not consume a real attempt.
  @max_startup_delay_seconds 15 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"scope" => scope}})
      when scope in ["hot", "all"] do
    if attempt == 1 do
      {:snooze, :rand.uniform(@max_startup_delay_seconds)}
    else
      scope |> scope_atom() |> run()
    end
  end

  def perform(%Oban.Job{args: args}), do: {:cancel, {:unknown_scope, args}}

  @doc false
  # `today` and `refresh_fun` are the seams that make selection and crash
  # isolation testable without a relay.
  def run(scope, today \\ Date.utc_today(), refresh_fun \\ &refresh_show/2) do
    due = AiringRefresh.due_seasons(today, scope)
    total = length(due)

    failures =
      for {item, seasons} <- due,
          {:error, reason} <- [safe_refresh(item, seasons, refresh_fun)],
          do: {item, reason}

    Logger.info("Airing episode refresh completed",
      scope: scope,
      total: total,
      failed: length(failures)
    )

    PassFailures.report(@job_name, "airing shows", failures, total)
    :ok
  end

  @doc false
  def refresh_show(media_item, season_numbers) do
    Media.refresh_seasons(media_item, season_numbers, actor_type: :job, actor_id: @job_name)
  end

  defp scope_atom("hot"), do: :hot
  defp scope_atom("all"), do: :all

  # A single bad show must not abort the pass. The ErrorTracker report keeps
  # the crash visible even though the pass carries on.
  defp safe_refresh(media_item, season_numbers, refresh_fun) do
    refresh_fun.(media_item, season_numbers)
  rescue
    error ->
      ErrorTracker.report(error, __STACKTRACE__, %{media_item_id: media_item.id})

      Logger.warning("Exception refreshing airing seasons, continuing pass",
        media_item_id: media_item.id,
        error: inspect(error)
      )

      {:error, {:exception, Exception.message(error)}}
  end
end
