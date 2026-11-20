defmodule Mydia.Jobs.CardigannHealthCheck do
  @moduledoc """
  Background job for checking health of enabled Cardigann indexers.

  Runs periodically (default: hourly) to test connections and update health
  status for all enabled Cardigann indexers.

  ## Manual Trigger

  To trigger a health check manually from IEx:

      Mydia.Jobs.CardigannHealthCheck.enqueue()
      # or for a specific indexer
      Mydia.Jobs.CardigannHealthCheck.enqueue(definition_id: "abc-123")

  ## Scheduled Health Checks

  The job runs hourly by default. Configure the schedule in Oban configuration.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Logger
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannFeatureFlags

  defmodule Args do
    @moduledoc false
    defstruct [:definition_id]

    @type t :: %__MODULE__{definition_id: String.t() | nil}

    def parse(raw) do
      %__MODULE__{definition_id: Map.get(raw, "definition_id")}
    end
  end

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)

    if CardigannFeatureFlags.enabled?() do
      if args.definition_id do
        perform_single_health_check(args.definition_id)
      else
        perform_all_health_checks()
      end
    else
      Logger.debug("[CardigannHealthCheckJob] Skipping - Cardigann feature disabled")
      :ok
    end
  end

  @doc """
  Enqueues a new health check job.

  ## Options

    * `:definition_id` - Check a specific indexer (optional)
    * `:schedule_in` - Schedule the job to run after N seconds

  ## Examples

      # Check all enabled indexers immediately
      CardigannHealthCheck.enqueue()

      # Check specific indexer
      CardigannHealthCheck.enqueue(definition_id: "abc-123")

      # Schedule to run in 1 hour
      CardigannHealthCheck.enqueue(schedule_in: 3600)
  """
  def enqueue(opts \\ []) do
    {schedule_in, job_opts} = Keyword.pop(opts, :schedule_in)
    definition_id = Keyword.get(job_opts, :definition_id)

    job_args = %{
      "definition_id" => definition_id
    }

    job =
      if schedule_in do
        new(job_args, schedule_in: schedule_in)
      else
        new(job_args)
      end

    Oban.insert(job)
  end

  # Private Functions

  defp perform_single_health_check(definition_id) do
    Logger.info("[CardigannHealthCheckJob] Checking health for indexer: #{definition_id}")

    case CardigannHealthCheck.test_connection(definition_id) do
      {:ok, result} ->
        log_result(definition_id, result)
        :ok

      {:error, reason} ->
        Logger.error("[CardigannHealthCheckJob] Failed to check indexer",
          definition_id: definition_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp perform_all_health_checks do
    Logger.info("[CardigannHealthCheckJob] Starting health checks for all enabled indexers")

    {:ok, results} = CardigannHealthCheck.check_all_enabled()

    total = map_size(results)
    successful = Enum.count(results, fn {_id, result} -> result.success end)
    failed = total - successful

    Logger.info("[CardigannHealthCheckJob] Health checks completed",
      total: total,
      successful: successful,
      failed: failed
    )

    # Log individual failures for monitoring
    Enum.each(results, fn
      {_id, %{success: true}} ->
        :ok

      # A tracker throttling Mydia is not broken; the result's message names
      # when the cooldown ends.
      {id, %{rate_limited: true} = result} ->
        Logger.info("[CardigannHealthCheckJob] Rate-limited by tracker: #{result.message}",
          definition_id: id
        )

      {id, result} ->
        Logger.warning("[CardigannHealthCheckJob] Indexer unhealthy",
          definition_id: id,
          status: result[:status],
          error: result[:error]
        )
    end)

    :ok
  end

  defp log_result(definition_id, result) do
    if result.success do
      Logger.info("[CardigannHealthCheckJob] Indexer healthy",
        definition_id: definition_id,
        status: result.status,
        response_time_ms: result.response_time_ms
      )
    else
      Logger.warning("[CardigannHealthCheckJob] Indexer unhealthy",
        definition_id: definition_id,
        status: result.status,
        error: result.error
      )
    end
  end
end
