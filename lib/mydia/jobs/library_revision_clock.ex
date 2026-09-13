defmodule Mydia.Jobs.LibraryRevisionClock do
  @moduledoc """
  The daily Oban wrapper around `Mydia.LibraryApi.RevisionClock.catch_up/0`.

  A show becomes available when its episode's UTC `air_date` arrives, which is a
  clock transition with no database write for the revision triggers to observe.
  This job runs five minutes after midnight — far enough past the boundary that a
  slightly early scheduler tick still observes the new UTC day — and advances the
  aggregate revision of every show whose episode crossed it.

  Startup catch-up runs the same sweep synchronously via
  `Mydia.LibraryApi.RevisionClockBootstrap`, so a day missed while the node was
  down is handled on the next boot rather than waiting for this job.

  A failure is returned unchanged so Oban retries it.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 5

  require Logger

  alias Mydia.LibraryApi.RevisionClock

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case RevisionClock.catch_up() do
      {:ok, marked} ->
        Logger.info("Library revision clock advanced, marked #{marked} media item(s)")
        :ok

      {:error, reason} = error ->
        Logger.error("Library revision clock failed: #{inspect(reason)}")
        error
    end
  end
end
