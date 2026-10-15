defmodule Mydia.Jobs.StartupJitter do
  @moduledoc """
  Delays a cron job's first run by a random snooze, so self-hosted installs do
  not all hit the shared metadata relay at the same crontab minute.

  A job is on its first run when it has never been snoozed. That is read from
  `meta["snoozed"]`, never from `attempt`: since Oban 2.24 a snooze rolls
  `attempt` back, so a job that snoozes whenever `attempt == 1` sees
  `attempt == 1` again on every wake and snoozes forever. That shipped once and
  stalled `Mydia.Jobs.MetadataRefresh` and `Mydia.Jobs.AiringEpisodeRefresh`
  on every install for a month.

  Every `{:snooze, _}` in `lib/` goes through this module, which
  `test/mydia/jobs/startup_jitter_test.exs` enforces.
  """

  require Logger

  @doc """
  Returns `{:snooze, seconds}` with `seconds` in `1..max_seconds` on the job's
  first run, and `:run` once it has snoozed.

  Pair it with `with` so the snooze passes straight through:

      with :run <- StartupJitter.delay(job, 15 * 60), do: run_pass()
  """
  @spec delay(Oban.Job.t(), pos_integer()) :: {:snooze, pos_integer()} | :run
  def delay(%Oban.Job{} = job, max_seconds) when is_integer(max_seconds) and max_seconds > 0 do
    if snoozed?(job) do
      :run
    else
      seconds = :rand.uniform(max_seconds)
      Logger.info("#{job.worker} scheduled, snoozing #{seconds}s to spread relay load")
      {:snooze, seconds}
    end
  end

  defp snoozed?(%Oban.Job{meta: %{"snoozed" => count}}) when is_integer(count), do: count > 0
  defp snoozed?(%Oban.Job{}), do: false
end
