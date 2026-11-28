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
    :ok = Alerts.refresh(ctx.name)
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

  describe "a slow gather" do
    setup do
      test_pid = self()
      name = :"alerts_slow_#{System.unique_integer([:positive])}"

      gather = fn ->
        send(test_pid, :gathering)
        Process.sleep(:infinity)
      end

      start_supervised!(
        {Alerts,
         name: name,
         topic: "health:alerts:#{name}",
         built_in_topic: "built_in:#{name}",
         interval_ms: 20,
         gather: gather,
         now: fn -> @t0 end}
      )

      %{slow: name}
    end

    test "never blocks current/0", %{slow: name} do
      assert_receive :gathering

      {micros, alerts} = :timer.tc(fn -> Alerts.current(name) end)
      assert alerts == []
      assert micros < 200_000
    end

    test "skips ticks while one is still running", %{slow: _name} do
      assert_receive :gathering
      refute_receive :gathering, 200
    end
  end

  test "a raising gather does not take the watcher down" do
    name = :"alerts_raise_#{System.unique_integer([:positive])}"
    test_pid = self()

    pid =
      start_supervised!(
        {Alerts,
         name: name,
         topic: "health:alerts:#{name}",
         built_in_topic: "built_in:#{name}",
         interval_ms: 20,
         gather: fn ->
           send(test_pid, :raising)
           raise "boom"
         end,
         now: fn -> @t0 end},
        id: name
      )

    # Two gathers: the second can only start once the first one's failure was
    # handled and the watcher survived it.
    assert_receive :raising
    assert_receive :raising
    assert Process.alive?(pid)
    assert Alerts.current(name) == []
  end

  test "broadcasts when an alert's detail changes", ctx do
    ctx.start.(:timer.hours(1))
    :ok = Alerts.refresh(ctx.name)
    ctx.set.(:now, minutes(10))
    :ok = Alerts.refresh(ctx.name)
    assert_receive {:health_alerts, [%Alert{detail: nil}]}

    ctx.set.(:obs, %{vpn: %{@obs | detail: "new"}})
    ctx.set.(:now, minutes(11))
    :ok = Alerts.refresh(ctx.name)
    assert_receive {:health_alerts, [%Alert{detail: "new"}]}
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
