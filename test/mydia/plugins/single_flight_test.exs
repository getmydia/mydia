defmodule Mydia.Plugins.SingleFlightTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.SingleFlight

  setup do
    name = :"sf_#{System.unique_integer([:positive])}"

    # Supervised rather than start_link + on_exit: start_link links the server
    # to the test process, so it is already dying when on_exit runs and a
    # GenServer.stop there races the link exit for a flaky `:noproc`.
    start_supervised!({SingleFlight, name: name})

    %{sf: name}
  end

  test "acquire/release lets a second waiter in", %{sf: sf} do
    assert :ok = SingleFlight.acquire("p", :wait, sf)
    assert :ok = SingleFlight.release("p", sf)
    assert :ok = SingleFlight.acquire("p", :wait, sf)
  end

  test ":skip returns :busy while held, :ok when free", %{sf: sf} do
    parent = self()

    # A holder process keeps the lock until told to release.
    holder =
      spawn(fn ->
        :ok = SingleFlight.acquire("p", :wait, sf)
        send(parent, :acquired)

        receive do
          :release -> SingleFlight.release("p", sf)
        end
      end)

    assert_receive :acquired

    assert :busy = SingleFlight.acquire("p", :skip, sf)

    send(holder, :release)
    # Give the release time to process, then the lock is free.
    Process.sleep(20)
    assert :ok = SingleFlight.acquire("p", :skip, sf)
  end

  test ":wait queues behind the holder and runs after release", %{sf: sf} do
    parent = self()
    :ok = SingleFlight.acquire("p", :wait, sf)

    waiter =
      spawn(fn ->
        :ok = SingleFlight.acquire("p", :wait, sf)
        send(parent, :waiter_acquired)
      end)

    _ = waiter
    # The waiter is blocked while we hold the lock.
    refute_receive :waiter_acquired, 100

    :ok = SingleFlight.release("p", sf)
    assert_receive :waiter_acquired, 1_000
  end

  test "a crashed holder auto-releases the lock", %{sf: sf} do
    parent = self()

    holder =
      spawn(fn ->
        :ok = SingleFlight.acquire("p", :wait, sf)
        send(parent, :acquired)
        receive do: (:die -> exit(:boom))
      end)

    assert_receive :acquired
    assert :busy = SingleFlight.acquire("p", :skip, sf)

    Process.exit(holder, :kill)
    # The monitor fires and frees the lock for the next acquirer.
    Process.sleep(20)
    assert :ok = SingleFlight.acquire("p", :skip, sf)
  end

  test "different slugs are independent", %{sf: sf} do
    assert :ok = SingleFlight.acquire("a", :wait, sf)
    assert :ok = SingleFlight.acquire("b", :skip, sf)
    assert :busy = SingleFlight.acquire("a", :skip, sf)
  end

  test "run/4 holds the lock for the duration and releases after", %{sf: sf} do
    assert :held = SingleFlight.run("p", :wait, fn -> :held end, sf)
    # Lock was released, so it can be taken again.
    assert :ok = SingleFlight.acquire("p", :skip, sf)
  end

  test "run/4 in :skip mode returns {:busy} without running fun when held", %{sf: sf} do
    parent = self()

    spawn(fn ->
      :ok = SingleFlight.acquire("p", :wait, sf)
      send(parent, :acquired)
      receive do: (:never -> :ok)
    end)

    assert_receive :acquired
    assert {:busy} = SingleFlight.run("p", :skip, fn -> flunk("should not run") end, sf)
  end
end
