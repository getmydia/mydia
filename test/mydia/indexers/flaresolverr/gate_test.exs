defmodule Mydia.Indexers.FlareSolverr.GateTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.FlareSolverr.Gate

  setup do
    server = start_supervised!({Gate, name: :"gate_#{System.unique_integer([:positive])}"})
    %{server: server}
  end

  test "never runs more than :limit functions at once", %{server: server} do
    in_flight = :counters.new(2, [])

    work = fn ->
      :counters.add(in_flight, 1, 1)
      now = :counters.get(in_flight, 1)
      if now > :counters.get(in_flight, 2), do: :counters.put(in_flight, 2, now)
      Process.sleep(30)
      :counters.sub(in_flight, 1, 1)
      :done
    end

    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> Gate.run(work, server: server, limit: 2) end) end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &(&1 == :done))
    assert :counters.get(in_flight, 2) == 2
  end

  describe "when the gate process is unavailable" do
    test "a gate that was never started returns :flaresolverr_busy" do
      assert {:error, :flaresolverr_busy} =
               Gate.run(fn -> :ran end, server: :nonexistent_gate_name)
    end

    test "a gate that was stopped returns :flaresolverr_busy" do
      name = :"stopped_gate_#{System.unique_integer([:positive])}"
      start_supervised!({Gate, name: name}, id: name)
      # stop_supervised!, not GenServer.stop: the test supervisor restarts a
      # stopped child under the same name, racing the call below.
      :ok = stop_supervised!(name)

      assert {:error, :flaresolverr_busy} = Gate.run(fn -> :ran end, server: name)
    end
  end

  test "a caller that cannot get a slot in time gets :flaresolverr_busy", %{server: server} do
    parent = self()

    holder =
      Task.async(fn ->
        Gate.run(
          fn ->
            send(parent, :holding)
            Process.sleep(500)
          end,
          server: server,
          limit: 1
        )
      end)

    assert_receive :holding

    assert {:error, :flaresolverr_busy} =
             Gate.run(fn -> :ran end, server: server, limit: 1, timeout: 50)

    Task.await(holder)
    # The timed-out waiter must not have kept a slot.
    assert :ran = Gate.run(fn -> :ran end, server: server, limit: 1, timeout: 500)
  end

  test "a caller killed while holding a slot releases it", %{server: server} do
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        Gate.run(
          fn ->
            send(parent, :holding)
            Process.sleep(:infinity)
          end,
          server: server,
          limit: 1
        )
      end)

    assert_receive :holding
    Process.exit(pid, :kill)
    assert :ran = Gate.run(fn -> :ran end, server: server, limit: 1, timeout: 500)
  end

  test "an exception inside the function still releases the slot", %{server: server} do
    assert_raise RuntimeError, fn ->
      Gate.run(fn -> raise "boom" end, server: server, limit: 1)
    end

    assert :ran = Gate.run(fn -> :ran end, server: server, limit: 1, timeout: 500)
  end
end
