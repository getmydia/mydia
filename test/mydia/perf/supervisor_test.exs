defmodule Mydia.Perf.SupervisorTest do
  use ExUnit.Case, async: false

  test "the application starts it right after Mydia.Events.Writer" do
    children = Mydia.Application.children(queues: [default: 1])

    writer = Enum.find_index(children, &(&1 == Mydia.Events.Writer))
    perf = Enum.find_index(children, &(&1 == Mydia.Perf.Supervisor))

    assert is_integer(writer)
    assert perf == writer + 1
  end

  test "starts Peep before the flusher" do
    assert [{Peep, peep_opts}, Mydia.Perf.Flusher] = Mydia.Perf.Supervisor.children()
    assert peep_opts[:name] == Mydia.Perf.Peep
    assert length(peep_opts[:metrics]) == length(Mydia.Perf.Metrics.all())
  end

  test "ignores itself when disabled, as the test config is" do
    assert Mydia.Perf.Supervisor.init([]) == :ignore
  end

  test "enabled?/2 needs the config flag and no CLI mode" do
    assert Mydia.Perf.enabled?([enabled: true], false)
    refute Mydia.Perf.enabled?([enabled: true], true)
    refute Mydia.Perf.enabled?([enabled: false], false)
    refute Mydia.Perf.enabled?([], false)
  end
end
