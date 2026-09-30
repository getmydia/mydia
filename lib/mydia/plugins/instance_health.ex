defmodule Mydia.Plugins.InstanceHealth do
  @moduledoc """
  Cached health for plugin instances, from the guest's `check-health` export
  (contract 1.5).

  Same shape as `Mydia.MediaServer.Health`: a GenServer over an ETS cache and a
  5-minute background loop over every enabled instance of every enabled 1.5
  plugin. `status_map/1` never performs I/O, so a LiveView mount cannot block
  on an unreachable server. "Test" in the admin UI calls `check/2` with
  `force: true`.

  A pre-1.5 guest has no `check-health` export, so its instances report
  `:unsupported` and the guest is never called.
  """

  use GenServer

  require Logger

  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances

  @check_interval :timer.minutes(5)
  # Twice the loop interval, so an entry never expires before the next round
  # has had time to replace it.
  @cache_ttl 2 * @check_interval
  @table :plugin_instance_health

  @type status ::
          :ok | :degraded | :unauthorized | :unreachable | :unknown | :disabled | :unsupported
  @type result :: %{
          status: status(),
          message: String.t() | nil,
          action: :reconnect | :confirm_endpoints | nil,
          checked_at: DateTime.t() | nil
        }

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Checks one instance, from the cache unless `force: true`.

  `:checker` replaces `Mydia.Plugins.invoke_check_health/2` in tests.
  """
  @spec check(binary(), keyword()) :: {:ok, result()} | {:error, :not_found}
  def check(instance_id, opts \\ []) do
    checker = Keyword.get(opts, :checker, &Plugins.invoke_check_health/2)

    if Keyword.get(opts, :force, false) do
      perform(instance_id, checker)
    else
      case cached(instance_id) do
        {:ok, result} -> {:ok, result}
        :not_found -> perform(instance_id, checker)
      end
    end
  end

  @doc "Instance id to cached result. Never calls a guest."
  @spec status_map([Instance.t()]) :: %{binary() => result()}
  def status_map(instances) do
    Map.new(instances, fn instance -> {instance.id, cached_status(instance)} end)
  end

  @doc "Re-checks every enabled instance in the background."
  @spec refresh_all() :: :ok
  def refresh_all, do: GenServer.cast(__MODULE__, :refresh_all)

  ## GenServer

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule()
    if Keyword.get(opts, :check_on_start, true), do: send(self(), :perform_checks)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:perform_checks, state) do
    perform_all()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    perform_all()
    {:noreply, state}
  end

  ## Internals

  defp perform(instance_id, checker) do
    case Instances.get(instance_id) do
      nil ->
        {:error, :not_found}

      %Instance{enabled: false} ->
        {:ok, disabled()}

      %Instance{} = instance ->
        result =
          if supported?(instance.plugin_slug),
            do: run_check(instance, checker),
            else: unsupported()

        cache(instance.id, result)
        {:ok, result}
    end
  end

  defp run_check(instance, checker) do
    case checker.(instance.plugin_slug, instance.id) do
      {:ok, %{status: status} = health} ->
        %{
          status: normalize_status(status),
          message: Map.get(health, :message),
          action: normalize_action(Map.get(health, :action)),
          checked_at: DateTime.utc_now()
        }

      # A guest that predates the 1.5 exports (or a manifest without `setup`)
      # is reported as :unsupported; that is not an outage.
      {:error, %Error{type: :unsupported}} ->
        unsupported()

      # :guest_error (the guest returned Err), :not_found (plugin not running),
      # a timeout: the check could not complete, so the server is unreachable
      # as far as the admin can tell.
      {:error, reason} ->
        unreachable(error_message(reason))
    end
  rescue
    e ->
      Logger.warning("plugin health check for #{instance.id} raised: #{Exception.message(e)}")
      unreachable("health check failed: #{Exception.message(e)}")
  end

  defp perform_all do
    plugins = Plugins.list_plugins()

    live_ids =
      for %{slug: slug} <- plugins, instance <- Instances.list(slug), into: MapSet.new() do
        instance.id
      end

    evict_missing(live_ids)

    for %{enabled: true, slug: slug} <- plugins,
        supported?(slug),
        instance <- Instances.list_enabled(slug) do
      Task.start(fn -> perform(instance.id, &Plugins.invoke_check_health/2) end)
    end

    :ok
  end

  # Drop cache entries for instances that were deleted (or whose plugin is gone).
  defp evict_missing(live_ids) do
    for id <- :ets.select(@table, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        not MapSet.member?(live_ids, id) do
      :ets.delete(@table, id)
    end

    :ok
  end

  # The default for a slug with no memo is :v15, so an instance whose plugin
  # never started still reaches the checker, which then answers :not_found
  # (plugin not running) and caches :unreachable.
  defp supported?(slug), do: Host.contract_version(slug) == :v15

  defp normalize_status(s) when s in [:ok, :degraded, :unauthorized, :unreachable], do: s
  defp normalize_status(_), do: :unreachable

  defp normalize_action(nil), do: nil
  defp normalize_action(:none), do: nil
  defp normalize_action({:some, a}), do: normalize_action(a)
  defp normalize_action(:reconnect), do: :reconnect

  defp normalize_action(a) when a in [:"confirm-endpoints", :confirm_endpoints],
    do: :confirm_endpoints

  defp normalize_action(_), do: nil

  defp error_message(%Error{message: m}), do: m
  defp error_message(other), do: inspect(other)

  defp cached_status(%Instance{enabled: false}), do: disabled()

  defp cached_status(%Instance{} = instance) do
    case cached(instance.id) do
      {:ok, result} -> result
      :not_found -> unknown()
    end
  end

  defp cached(id) do
    case :ets.lookup(@table, id) do
      [{^id, result, at}] ->
        if System.monotonic_time(:millisecond) - at < @cache_ttl,
          do: {:ok, result},
          else: :not_found

      [] ->
        :not_found
    end
  rescue
    # The table does not exist when the GenServer is not started (test env).
    ArgumentError -> :not_found
  end

  defp cache(id, result) do
    :ets.insert(@table, {id, result, System.monotonic_time(:millisecond)})
  rescue
    ArgumentError -> :ok
  end

  defp schedule, do: Process.send_after(self(), :perform_checks, @check_interval)

  defp unknown, do: %{status: :unknown, message: nil, action: nil, checked_at: nil}
  defp disabled, do: %{status: :disabled, message: nil, action: nil, checked_at: nil}
  defp unsupported, do: %{status: :unsupported, message: nil, action: nil, checked_at: nil}

  defp unreachable(message),
    do: %{status: :unreachable, message: message, action: nil, checked_at: DateTime.utc_now()}
end
