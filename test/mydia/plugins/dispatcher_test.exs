defmodule Mydia.Plugins.DispatcherTest do
  # async: false — registers in the app-wide Mydia.Plugins.Registry and
  # subscribes to the shared "events:all" bus.
  use ExUnit.Case, async: false

  alias Mydia.Plugins.Dispatcher
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Phoenix.PubSub

  setup do
    Registry.clear()
    on_exit(&Registry.clear/0)
    :ok
  end

  defp register!(slug, events, opts \\ []) do
    plugin = %Plugin{
      slug: slug,
      name: slug,
      events: events,
      enabled: Keyword.get(opts, :enabled, true)
    }

    {:ok, _} = Registry.register(slug, plugin)
    :ok
  end

  # A dispatcher whose invoker reports back to the test process instead of
  # touching a live wasm guest.
  defp start_dispatcher!(reply_to) do
    invoker = fn plugin, event ->
      send(reply_to, {:invoked, plugin.slug, event.type})

      case plugin.slug do
        "boom" -> raise "boom plugin blew up"
        "slow" -> Process.sleep(50_000)
        _ -> {:ok, %{}}
      end
    end

    start_supervised!(
      {Dispatcher, name: :"disp_#{System.unique_integer([:positive])}", invoker: invoker}
    )
  end

  defp broadcast(type) do
    PubSub.broadcast(Mydia.PubSub, "events:all", {:event_created, %{type: type, metadata: %{}}})
  end

  test "R9: a catalog event reaches a subscribed plugin, not an unsubscribed one" do
    start_dispatcher!(self())
    register!("subbed", ["media_item.added"])
    register!("other", ["download.failed"])

    broadcast("media_item.added")

    assert_receive {:invoked, "subbed", "media_item.added"}, 1_000
    refute_receive {:invoked, "other", _}, 200
  end

  test "R2: one plugin raising does not prevent dispatch to the others, dispatcher stays up" do
    pid = start_dispatcher!(self())
    register!("boom", ["media_item.added"])
    register!("ok", ["media_item.added"])

    broadcast("media_item.added")

    assert_receive {:invoked, "ok", "media_item.added"}, 1_000
    assert_receive {:invoked, "boom", "media_item.added"}, 1_000

    # The raise was contained in the isolated task; the dispatcher survives and
    # keeps dispatching subsequent events.
    assert Process.alive?(pid)
    broadcast("media_item.added")
    assert_receive {:invoked, "ok", "media_item.added"}, 1_000
  end

  test "R2: a slow plugin does not block dispatch to the others" do
    start_dispatcher!(self())
    register!("slow", ["media_item.added"])
    register!("fast", ["media_item.added"])

    broadcast("media_item.added")

    # The fast plugin is invoked even though the slow one is mid-sleep, because
    # each invocation runs in its own task.
    assert_receive {:invoked, "fast", "media_item.added"}, 1_000
  end

  test "events outside the v1 catalog are ignored" do
    start_dispatcher!(self())
    register!("anything", ["media_item.added"])

    broadcast("media_item.exploded")

    refute_receive {:invoked, _, _}, 200
  end

  test "disabled plugins are not invoked" do
    start_dispatcher!(self())
    register!("off", ["media_item.added"], enabled: false)

    broadcast("media_item.added")

    refute_receive {:invoked, "off", _}, 200
  end

  test "download.completed (a :system-actor event) dispatches correctly" do
    start_dispatcher!(self())
    register!("dl", ["download.completed"])

    PubSub.broadcast(
      Mydia.PubSub,
      "events:all",
      {:event_created, %{type: "download.completed", actor_type: :system, metadata: %{}}}
    )

    assert_receive {:invoked, "dl", "download.completed"}, 1_000
  end

  test "R14: an event is not delivered back to the plugin that originated it" do
    start_dispatcher!(self())
    register!("simkl_sync", ["playback.finished"])
    register!("other", ["playback.finished"])

    PubSub.broadcast(
      Mydia.PubSub,
      "events:all",
      {:event_created, %{type: "playback.finished", metadata: %{"origin" => "plugin:simkl_sync"}}}
    )

    assert_receive {:invoked, "other", "playback.finished"}, 1_000
    refute_receive {:invoked, "simkl_sync", _}, 200
  end

  test "R14: an instance-qualified origin is not delivered back to that plugin" do
    start_dispatcher!(self())
    register!("plex", ["playback.finished"])
    register!("other", ["playback.finished"])

    PubSub.broadcast(
      Mydia.PubSub,
      "events:all",
      {:event_created,
       %{type: "playback.finished", metadata: %{"origin" => "plugin:plex:0b7e-1234"}}}
    )

    assert_receive {:invoked, "other", "playback.finished"}, 1_000
    refute_receive {:invoked, "plex", _}, 200
  end

  test "a non-binary origin does not crash the dispatcher and is delivered" do
    pid = start_dispatcher!(self())
    register!("other", ["playback.finished"])

    PubSub.broadcast(
      Mydia.PubSub,
      "events:all",
      {:event_created, %{type: "playback.finished", metadata: %{"origin" => :player}}}
    )

    assert_receive {:invoked, "other", "playback.finished"}, 1_000
    assert Process.alive?(pid)
  end

  test "R14: a sync-origin event is delivered with the origin visible in metadata" do
    test_pid = self()

    invoker = fn plugin, event ->
      send(test_pid, {:got, plugin.slug, event.metadata["origin"]})
      {:ok, %{}}
    end

    start_supervised!(
      {Dispatcher, name: :"disp_origin_#{System.unique_integer([:positive])}", invoker: invoker}
    )

    register!("plex_watch", ["playback.finished"])

    PubSub.broadcast(
      Mydia.PubSub,
      "events:all",
      {:event_created, %{type: "playback.finished", metadata: %{"origin" => "sync:plex"}}}
    )

    assert_receive {:got, "plex_watch", "sync:plex"}, 1_000
  end
end
