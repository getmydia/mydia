defmodule Mydia.Health.AlertsTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Health.Alert
  alias Mydia.Health.Alerts

  @t0 ~U[2026-01-01 00:00:00Z]
  @obs %{title: "VPN down", detail: nil, fix_path: "/admin/clients"}

  setup do
    {:ok, clock} = Agent.start_link(fn -> %{now: @t0, obs: %{vpn: @obs}} end)
    name = :"alerts_#{System.unique_integer([:positive])}"
    topic = "health:alerts:#{name}"
    built_in_topic = "built_in:#{name}"

    start = fn interval_ms ->
      start_supervised!(
        {Alerts,
         name: name,
         topic: topic,
         built_in_topic: built_in_topic,
         interval_ms: interval_ms,
         gather: fn -> Agent.get(clock, & &1.obs) end,
         now: fn -> Agent.get(clock, & &1.now) end}
      )
    end

    set = fn key, value -> Agent.update(clock, &Map.put(&1, key, value)) end
    Phoenix.PubSub.subscribe(Mydia.PubSub, topic)

    %{name: name, start: start, set: set, built_in_topic: built_in_topic}
  end

  defp minutes(n), do: DateTime.add(@t0, n * 60, :second)

  test "current is empty when not running" do
    assert Alerts.current(:no_such_alerts_server) == []
  end

  test "topic" do
    assert Alerts.topic() == "health:alerts"
  end

  test "raises after the threshold and broadcasts once", ctx do
    ctx.start.(:timer.hours(1))
    :ok = Alerts.refresh(ctx.name)
    assert Alerts.current(ctx.name) == []
    refute_receive {:health_alerts, _}, 50

    ctx.set.(:now, minutes(10))
    :ok = Alerts.refresh(ctx.name)
    assert [%Alert{key: :vpn}] = Alerts.current(ctx.name)
    assert_receive {:health_alerts, [%Alert{key: :vpn}]}

    ctx.set.(:now, minutes(11))
    :ok = Alerts.refresh(ctx.name)
    refute_receive {:health_alerts, _}, 50
  end

  test "broadcasts the empty list when cleared", ctx do
    ctx.start.(:timer.hours(1))
    ctx.set.(:now, minutes(10))
    :ok = Alerts.refresh(ctx.name)
    assert_receive {:health_alerts, [_]}

    ctx.set.(:obs, %{vpn: nil})
    ctx.set.(:now, minutes(11))
    :ok = Alerts.refresh(ctx.name)
    ctx.set.(:now, minutes(16))
    :ok = Alerts.refresh(ctx.name)
    assert_receive {:health_alerts, []}
    assert Alerts.current(ctx.name) == []
  end

  test "re-evaluates on built-in status broadcast", ctx do
    ctx.start.(:timer.hours(1))
    :ok = Alerts.refresh(ctx.name)
    ctx.set.(:now, minutes(10))

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      ctx.built_in_topic,
      {:built_in_status, %Status{}}
    )

    assert_receive {:health_alerts, [%Alert{key: :vpn}]}
  end
end
