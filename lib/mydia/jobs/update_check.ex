defmodule Mydia.Jobs.UpdateCheck do
  @moduledoc """
  Runs `Mydia.UpdateCheck` shortly after boot and once a week.

  Every install's weekly cron fires at the same UTC minute, so that run only
  reschedules itself to a random moment within the next day; the relay then
  sees checks spread out instead of all at once. The boot run waits 10 to 60
  minutes, which also keeps a crash-looping container from checking on every
  restart.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 6 * 3600, states: [:available, :scheduled]]

  require Logger

  @spread_seconds 24 * 3600

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"spread" => true}}) do
    Mydia.UpdateCheck.run()
    :ok
  end

  def perform(%Oban.Job{}) do
    {:ok, _job} = schedule(:rand.uniform(@spread_seconds))
    :ok
  end

  @doc "Queues the after-boot check. Never raises."
  @spec enqueue_after_boot() :: :ok
  def enqueue_after_boot do
    {:ok, _job} = schedule(600 + :rand.uniform(3000))
    :ok
  rescue
    error ->
      Logger.debug("Update check: failed to enqueue on boot", error: inspect(error))
      :ok
  end

  defp schedule(seconds), do: %{"spread" => true} |> new(schedule_in: seconds) |> Oban.insert()
end
