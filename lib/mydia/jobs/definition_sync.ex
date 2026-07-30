defmodule Mydia.Jobs.DefinitionSync do
  @moduledoc """
  Background job for syncing Cardigann indexer definitions from GitHub.

  Runs daily to fetch the latest indexer definitions from the Prowlarr/Indexers
  repository and update the local database.

  ## Manual Trigger

  To trigger a sync manually from IEx:

      Mydia.Jobs.DefinitionSync.enqueue()
      # or with a limit for testing
      Mydia.Jobs.DefinitionSync.enqueue(limit: 10)

  ## Scheduled Sync

  The job runs daily at 3:00 AM UTC by default. Configure the schedule in Oban configuration.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger
  alias Mydia.Indexers.DefinitionSync
  alias Mydia.Indexers.CardigannFeatureFlags

  defmodule Args do
    @moduledoc false
    defstruct [:limit]

    @type t :: %__MODULE__{limit: integer() | nil}

    def parse(raw) do
      %__MODULE__{limit: Map.get(raw, "limit")}
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)

    if CardigannFeatureFlags.enabled?() do
      opts = if args.limit, do: [limit: args.limit], else: []

      Logger.info("[DefinitionSyncJob] Starting scheduled sync", opts: opts)

      case DefinitionSync.sync_from_github(opts) do
        {:ok, stats} ->
          Logger.info("[DefinitionSyncJob] Sync completed successfully", stats: stats)
          :ok

        {:error, reason} ->
          Logger.error("[DefinitionSyncJob] Sync failed", reason: inspect(reason))
          {:error, reason}
      end
    else
      Logger.debug("[DefinitionSyncJob] Skipping sync - Cardigann feature disabled")
      :ok
    end
  end

  @doc """
  Enqueues a new definition sync job.

  ## Options

    * `:limit` - Maximum number of definitions to sync (for testing)
    * `:schedule_in` - Schedule the job to run after N seconds

  ## Examples

      # Run immediately
      DefinitionSync.enqueue()

      # Run with limit (testing)
      DefinitionSync.enqueue(limit: 5)

      # Schedule to run in 1 hour
      DefinitionSync.enqueue(schedule_in: 3600)
  """
  def enqueue(opts \\ []) do
    {schedule_in, job_opts} = Keyword.pop(opts, :schedule_in)

    job_args = %{
      "limit" => Keyword.get(job_opts, :limit)
    }

    job =
      if schedule_in do
        new(job_args, schedule_in: schedule_in)
      else
        new(job_args)
      end

    Oban.insert(job)
  end
end
