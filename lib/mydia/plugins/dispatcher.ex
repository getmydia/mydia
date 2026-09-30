defmodule Mydia.Plugins.Dispatcher do
  @moduledoc """
  Fans `"events:all"` events out to subscribed plugins (U5, KTD3).

  A supervised `GenServer` subscribes to the existing `"events:all"` PubSub bus
  and, for each `{:event_created, %Event{}}` whose `type` is in the v1 catalog
  (`Mydia.Plugins.Manifest.event_catalog/0`), invokes every enabled plugin
  subscribed to that type. No new emission sites are added — the dispatcher is a
  pure consumer of the bus.

  ## Isolation (R2)

  Each plugin invocation runs in its own supervised `Task` (off
  `Mydia.TaskSupervisor`), and any raise/exit/throw inside it is caught and
  logged. A slow or crashing plugin therefore cannot block the bus, starve other
  plugins, or take the dispatcher down — dispatch is fail-soft. The per-call
  fuel/timeout safety floor lives in `Mydia.Plugins.Host` (the dispatch path
  passes `force_fuel: true`).

  ## Testability

  The function that actually invokes a plugin is injectable via the `:invoker`
  option (a 2-arity `(plugin, event)` fun, defaulting to
  `Mydia.Plugins.invoke_plugin/2`), so dispatch routing can be tested without a
  live wasm guest.
  """

  use GenServer

  require Logger

  alias Mydia.Plugins
  alias Mydia.Plugins.Manifest
  alias Phoenix.PubSub

  @pubsub Mydia.PubSub
  @topic "events:all"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    PubSub.subscribe(@pubsub, @topic)
    invoker = Keyword.get(opts, :invoker, &Plugins.invoke_plugin/2)
    {:ok, %{invoker: invoker}}
  end

  @impl true
  def handle_info({:event_created, %{type: type} = event}, %{invoker: invoker} = state) do
    if type in Manifest.event_catalog() do
      origin = event_origin(event)

      for plugin <- Plugins.subscribers(type), not suppressed?(origin, plugin.slug) do
        run_isolated(invoker, plugin, event)
      end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The event's origin (e.g. "plugin:simkl_sync", "sync:plex", "player") lives in
  # its metadata bag. Tolerant of both string and atom keys since events may be
  # built in either shape across the codebase.
  defp event_origin(%{metadata: %{} = meta}), do: meta["origin"] || meta[:origin]
  defp event_origin(_), do: nil

  @doc false
  # Never deliver an event back to the plugin that originated it (R14). A 1.4
  # write is tagged "plugin:<slug>:<instance_id>"; every instance of the same
  # plugin is suppressed, since each instance's scheduled push already skips
  # rows whose `origin` is its own and pushes a sibling's writes (spec 1.7).
  # Events from players, other plugins, or sync providers pass through.
  @spec suppressed?(String.t() | nil, String.t()) :: boolean()
  def suppressed?(nil, _slug), do: false

  def suppressed?(origin, slug) when is_binary(origin) do
    own = "plugin:" <> slug
    origin == own or String.starts_with?(origin, own <> ":")
  end

  # Run one plugin invocation in an isolated, supervised task. Crashes are
  # caught and logged so one misbehaving plugin never affects the others or the
  # dispatcher (R2, fail-soft).
  defp run_isolated(invoker, plugin, event) do
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      try do
        case invoker.(plugin, event) do
          {:error, error} ->
            Logger.warning("plugin #{plugin.slug} dispatch error: #{inspect(error)}")

          _ok ->
            :ok
        end
      rescue
        e ->
          Logger.warning("plugin #{plugin.slug} dispatch raised: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.warning("plugin #{plugin.slug} dispatch #{kind}: #{inspect(reason)}")
      end
    end)
  end
end
