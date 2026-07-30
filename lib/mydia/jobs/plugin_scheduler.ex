defmodule Mydia.Jobs.PluginScheduler do
  @moduledoc """
  Fixed-interval plugin tick (U4).

  Oban's crontab is compile-time, so rather than a per-plugin schedule this single
  every-minute worker checks each enabled, `schedule:interval`-granted plugin's
  manifest interval against `last_scheduled_at` and invokes `on-schedule` for the
  ones that are due. The worker is `unique`, so a still-running tick dedupes the
  next insert — ticks never pile up.

  Per-plugin non-reentrancy is enforced one level down: `invoke_plugin_schedule/2`
  acquires the single-flight lock in `:skip` mode, so a plugin already mid-sync
  (reactive or scheduled) is skipped without touching its bookkeeping and retried
  next tick. `last_scheduled_at` is written only on *completion*, so a crash
  mid-invocation re-runs next tick — safe because the sync is idempotent (R15).

  Consecutive failures drive exponential backoff (`@backoff_cap`), so a broken
  plugin backs off instead of hammering every minute; a success resets it.
  """

  use Oban.Worker,
    queue: :plugins,
    max_attempts: 1,
    # No explicit :states — max_attempts: 1 means this job can never reach
    # :retryable, so the states list would never actually differ from
    # Oban's own default incomplete-state set. Inheriting it is one fewer
    # place to keep in sync (and avoids Oban 2.23's compile-time warning for
    # partial :states lists).
    unique: [period: 120]

  import Ecto.Query

  require Logger

  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Manifest
  alias Mydia.Repo
  alias Mydia.Settings.PluginConfig

  # Failures double the effective interval, capped at 2^@backoff_cap.
  @backoff_cap 4

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    tick(DateTime.utc_now(), &Plugins.invoke_plugin_schedule/1)
    :ok
  end

  @doc """
  Runs one scheduler tick at `now`, invoking due plugins through `invoker`
  (a 1-arity `slug -> Host.call result`). Exposed so the selection, backoff, and
  result-handling logic can be tested without a live wasm guest.
  """
  @spec tick(DateTime.t(), (String.t() -> {:ok, term()} | {:error, term()})) :: :ok
  def tick(now, invoker) do
    candidate_configs()
    |> Enum.filter(&(scheduled?(&1) and due?(&1, now)))
    |> Enum.each(&run_one(&1, now, invoker))

    :ok
  end

  @doc false
  # Exposed for tests: the effective interval after backoff.
  @spec effective_interval(pos_integer(), non_neg_integer()) :: pos_integer()
  def effective_interval(base_minutes, failures) do
    base_minutes * Integer.pow(2, min(failures, @backoff_cap))
  end

  defp candidate_configs do
    Repo.all(from c in PluginConfig, where: c.enabled == true)
  end

  # A plugin participates only when its manifest declares a schedule AND the
  # admin granted schedule:interval (deny-by-default — a manifest schedule alone
  # never ticks).
  defp scheduled?(%PluginConfig{} = config) do
    interval = Manifest.schedule_interval_minutes(Map.get(config.manifest || %{}, "schedule"))
    granted? = Map.has_key?(config.granted_capabilities || %{}, "schedule:interval")
    is_integer(interval) and granted?
  end

  defp due?(%PluginConfig{last_scheduled_at: nil}, _now), do: true

  defp due?(%PluginConfig{} = config, now) do
    base = Manifest.schedule_interval_minutes(Map.get(config.manifest, "schedule"))
    effective = effective_interval(base, config.consecutive_schedule_failures || 0)
    DateTime.diff(now, config.last_scheduled_at, :minute) >= effective
  end

  defp run_one(%PluginConfig{slug: slug} = config, now, invoker) do
    case invoker.(slug) do
      # Already in flight — leave bookkeeping untouched and retry next tick.
      {:error, %Error{type: :busy}} ->
        :skip

      {:ok, result} ->
        apply_connections_invalid(slug, result)
        mark_complete(config, now, :ok)

      {:error, reason} ->
        Logger.warning("plugin #{slug} schedule failed: #{inspect(reason)}")
        mark_complete(config, now, :error)
    end
  end

  # A guest may name users whose connection is invalid (e.g. a 401). Only users
  # holding an active connection to this plugin are flipped to `error`
  # (Connections.mark_errored enforces it), so a guest can't mass-error state.
  defp apply_connections_invalid(slug, result) when is_map(result) do
    case Map.get(result, "connections_invalid") do
      ids when is_list(ids) ->
        user_ids = Enum.filter(ids, &is_binary/1)
        if user_ids != [], do: Connections.mark_errored(slug, user_ids)

      _ ->
        :ok
    end
  end

  defp apply_connections_invalid(_slug, _result), do: :ok

  defp mark_complete(%PluginConfig{} = config, now, outcome) do
    failures =
      case outcome do
        :ok -> 0
        :error -> (config.consecutive_schedule_failures || 0) + 1
      end

    config
    |> Ecto.Changeset.change(
      last_scheduled_at: DateTime.truncate(now, :microsecond),
      consecutive_schedule_failures: failures
    )
    |> Repo.update()
  end
end
