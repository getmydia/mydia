defmodule Mydia.Jobs.ImportListScheduler do
  @moduledoc """
  Oban worker that schedules import list sync jobs.

  This worker runs periodically (every 15 minutes) and checks which enabled
  import lists are due for sync based on their last sync time and interval.
  It enqueues `ImportListSync` jobs for each list that needs syncing.

  ## Scheduling

  Configure in Oban crontab:

      {Oban.Plugins.Cron, crontab: [
        {"*/15 * * * *", Mydia.Jobs.ImportListScheduler}
      ]}
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1

  require Logger

  alias Mydia.ImportLists
  alias Mydia.ImportLists.FeatureFlags
  alias Mydia.Jobs.ImportListSync

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if FeatureFlags.enabled?() do
      Logger.info("[ImportListScheduler] Checking for import lists due for sync")

      due_lists = ImportLists.list_sync_due_lists()

      Logger.info("[ImportListScheduler] Found #{length(due_lists)} lists due for sync")

      Enum.each(due_lists, fn import_list ->
        case ImportListSync.enqueue(import_list.id) do
          {:ok, _job} ->
            Logger.debug("[ImportListScheduler] Enqueued sync for list",
              import_list_id: import_list.id,
              name: import_list.name
            )

          {:error, reason} ->
            Logger.warning("[ImportListScheduler] Failed to enqueue sync",
              import_list_id: import_list.id,
              error: inspect(reason)
            )
        end
      end)

      :ok
    else
      Logger.debug("[ImportListScheduler] Skipping - Import Lists feature disabled")
      :ok
    end
  end

  @doc """
  Manually triggers the scheduler.
  """
  def enqueue do
    new(%{})
    |> Oban.insert()
  end
end
