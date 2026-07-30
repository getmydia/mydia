defmodule Mydia.Jobs.MetadataRefresh do
  @moduledoc """
  Background job for refreshing media metadata.

  This job:
  - Fetches the latest metadata from providers
  - Updates media items with fresh data
  - For TV shows, updates episode information
  - Can be triggered manually or scheduled

  The refresh itself lives in `Mydia.Media.Refresh`; this module is the Oban
  wrapper around it. A full pass isolates each item so one bad media item
  cannot abort the run, and reports its failures through `Mydia.Events` rather
  than reporting success regardless of outcome.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Events, Media}
  alias Mydia.Media.Refresh

  defmodule Args do
    @moduledoc false
    defstruct [:media_item_id, refresh_all: false, fetch_episodes: true, skip_delay: false]

    @type t :: %__MODULE__{
            media_item_id: String.t() | nil,
            refresh_all: boolean(),
            fetch_episodes: boolean(),
            skip_delay: boolean()
          }

    def parse(%{"media_item_id" => media_item_id} = raw) do
      %__MODULE__{
        media_item_id: media_item_id,
        fetch_episodes: Map.get(raw, "fetch_episodes", true),
        skip_delay: Map.get(raw, "skip_delay", false)
      }
    end

    def parse(%{"refresh_all" => true} = raw) do
      %__MODULE__{
        refresh_all: true,
        skip_delay: Map.get(raw, "skip_delay", false)
      }
    end

    def parse(raw) when raw == %{} do
      %__MODULE__{refresh_all: true, skip_delay: true}
    end
  end

  # Cap on how many individual failures are attached to the reported event.
  @max_failure_samples 10

  # Random jitter range for scheduled refresh_all runs (0-30 minutes, in seconds).
  @max_startup_delay_seconds 30 * 60

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => media_item_id} = raw_args}) do
    args = Args.parse(raw_args)
    run_one(media_item_id, args.fetch_episodes)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{attempt: attempt, args: %{"refresh_all" => true} = raw_args}) do
    args = Args.parse(raw_args)

    # Spread load across self-hosted instances hitting the shared metadata relay
    # at 05:00 Sunday. Snoozing releases the queue slot instead of holding it for
    # up to half an hour, and Oban increments max_attempts so the jitter does not
    # consume one of the pass's real attempts.
    if attempt == 1 and not args.skip_delay do
      delay_seconds = :rand.uniform(@max_startup_delay_seconds)

      Logger.info("Metadata refresh scheduled, snoozing #{delay_seconds}s to spread relay load")

      {:snooze, delay_seconds}
    else
      run_all()
    end
  end

  # Manual trigger from the UI sends empty args.
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) when raw_args == %{}, do: run_all()

  @doc false
  # The default argument is the seam that makes crash isolation testable
  # without a mocking library.
  def run_all(refresh_fun \\ &refresh_one/1) do
    start_time = System.monotonic_time(:millisecond)
    media_items = Media.list_media_items(monitored: true)
    total = length(media_items)

    Logger.info("Refreshing metadata for #{total} media items")

    results = Enum.map(media_items, &safe_refresh(&1, refresh_fun))
    duration = System.monotonic_time(:millisecond) - start_time

    failures =
      results
      |> Enum.filter(&match?({_item, {:error, _reason}}, &1))
      |> Enum.map(fn {item, {:error, reason}} -> {item, reason} end)

    succeeded = total - length(failures)

    Logger.info("Metadata refresh all completed",
      duration_ms: duration,
      total: total,
      succeeded: succeeded,
      failed: length(failures)
    )

    report_failures(failures, total, succeeded)

    :ok
  end

  ## Private Functions

  defp run_one(media_item_id, fetch_episodes) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting metadata refresh", media_item_id: media_item_id)

    result =
      media_item_id
      |> Media.get_media_item!()
      |> Refresh.run(recover_by_title: true, fetch_episodes: fetch_episodes)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, updated} ->
        Logger.info("Metadata refresh completed",
          duration_ms: duration,
          media_item_id: updated.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Metadata refresh failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        {:error, reason}
    end
  rescue
    _e in Ecto.NoResultsError ->
      Logger.error("Media item not found", media_item_id: media_item_id)
      {:error, :not_found}
  end

  defp refresh_one(media_item) do
    Refresh.run(media_item, recover_by_title: true, fetch_episodes: false)
  end

  # A single bad item must not abort the pass. The ErrorTracker report is
  # load-bearing: rescuing without it would hide exactly the class of bug this
  # isolation exists to survive.
  defp safe_refresh(media_item, refresh_fun) do
    {media_item, refresh_fun.(media_item)}
  rescue
    error ->
      ErrorTracker.report(error, __STACKTRACE__, %{media_item_id: media_item.id})

      Logger.warning("Exception refreshing metadata, continuing pass",
        media_item_id: media_item.id,
        error: inspect(error)
      )

      {media_item, {:error, {:exception, Exception.message(error)}}}
  end

  defp report_failures([], _total, _succeeded), do: :ok

  defp report_failures(failures, total, succeeded) do
    failed = length(failures)

    samples =
      failures
      |> Enum.take(@max_failure_samples)
      |> Enum.map(fn {item, reason} ->
        %{
          "media_item_id" => item.id,
          "title" => item.title,
          "reason" => inspect(reason)
        }
      end)

    message =
      "#{failed} of #{total} media items failed to refresh " <>
        "(showing #{length(samples)} of #{failed})"

    Events.job_failed("metadata_refresh", message, %{
      "total" => total,
      "succeeded" => succeeded,
      "failed" => failed,
      "sample_failures" => samples
    })
  end
end
