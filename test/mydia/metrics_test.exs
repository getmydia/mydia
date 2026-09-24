defmodule Mydia.MetricsTest do
  use ExUnit.Case, async: false

  test "enabled?/2 needs the config flag and no CLI mode" do
    assert Mydia.Metrics.enabled?([enabled: true], false)
    refute Mydia.Metrics.enabled?([enabled: true], true)
    refute Mydia.Metrics.enabled?([enabled: false], false)
    refute Mydia.Metrics.enabled?([], false)
  end

  test "the supervisor ignores itself when disabled, as the test config is" do
    assert Mydia.Metrics.Supervisor.init([]) == :ignore
  end

  test "export/0 is :disabled when Peep is not running" do
    assert Mydia.Metrics.export() == :disabled
  end

  test "the application starts it right after Mydia.Perf.Supervisor" do
    children = Mydia.Application.children(queues: [default: 1])

    perf = Enum.find_index(children, &(&1 == Mydia.Perf.Supervisor))
    metrics = Enum.find_index(children, &(&1 == Mydia.Metrics.Supervisor))

    assert is_integer(perf)
    assert metrics == perf + 1
  end

  test "children are Peep, then the fast poller, then the slow poller" do
    assert [{Peep, peep_opts}, fast, slow] = Mydia.Metrics.Supervisor.children()
    assert peep_opts[:name] == Mydia.Metrics.Peep
    assert fast.id == Mydia.Metrics.FastPoller
    assert slow.id == Mydia.Metrics.SlowPoller
  end

  test "export/0 renders Prometheus text once Peep is running" do
    start_supervised!({Peep, name: Mydia.Metrics.Peep, metrics: Mydia.Metrics.Definitions.all()})

    :telemetry.execute([:mydia, :metrics, :downloads], %{value: 3}, %{state: "active"})

    assert {:ok, body} = Mydia.Metrics.export()
    body = IO.iodata_to_binary(body)
    assert body =~ ~s(mydia_downloads{state="active"} 3)
  end
end
