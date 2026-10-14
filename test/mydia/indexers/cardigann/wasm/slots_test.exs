defmodule Mydia.Indexers.Cardigann.Wasm.SlotsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Wasm.Slots

  setup do
    name = :"slots_#{System.unique_integer([:positive])}"
    start_supervised!({Slots, name: name, max: 2})
    {:ok, slots: name}
  end

  defp hold(slots, test_pid) do
    spawn(fn ->
      Slots.run(slots, 5_000, fn ->
        send(test_pid, {:holding, self()})
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp fill(slots) do
    a = hold(slots, self())
    b = hold(slots, self())
    assert_receive {:holding, _}
    assert_receive {:holding, _}
    {a, b}
  end

  # Waits until the server holds `expected` queued requests, so a test acts
  # only after its `:acquire` has really arrived.
  defp await_queued(slots, expected, attempts \\ 100) do
    cond do
      :queue.len(:sys.get_state(slots).queue) == expected ->
        :ok

      attempts == 0 ->
        flunk("expected #{expected} queued request(s) in #{inspect(slots)}")

      true ->
        Process.sleep(10)
        await_queued(slots, expected, attempts - 1)
    end
  end

  test "runs the function and returns its value", %{slots: slots} do
    assert {:ok, 42, _waited} = Slots.run(slots, 1_000, fn -> 42 end)
  end

  test "never runs more than max at once", %{slots: slots} do
    {a, b} = fill(slots)

    third = Task.async(fn -> Slots.run(slots, 5_000, fn -> :ran end) end)
    refute Task.yield(third, 100)

    send(a, :release)
    assert {:ok, :ran, waited} = Task.await(third)
    assert waited >= 100
    send(b, :release)
  end

  test "a caller whose timeout runs out in the queue gets :timeout and holds nothing",
       %{slots: slots} do
    {a, b} = fill(slots)

    assert {:error, :timeout} = Slots.run(slots, 50, fn -> :never end)

    send(a, :release)
    assert {:ok, :ok, _} = Slots.run(slots, 1_000, fn -> :ok end)
    send(b, :release)
  end

  test "a holder that dies frees its slot", %{slots: slots} do
    {a, b} = fill(slots)

    Process.exit(a, :kill)
    assert {:ok, :ok, _} = Slots.run(slots, 1_000, fn -> :ok end)
    send(b, :release)
  end

  test "a queued caller that is killed does not take a slot when one frees", %{slots: slots} do
    {a, b} = fill(slots)

    queued = spawn(fn -> Slots.run(slots, 5_000, fn -> :never end) end)
    ref = Process.monitor(queued)
    await_queued(slots, 1)
    Process.exit(queued, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    send(a, :release)
    assert {:ok, :ok, waited} = Slots.run(slots, 1_000, fn -> :ok end)
    assert waited < 500
    send(b, :release)
  end

  test "a caller queued when the server dies runs unslotted and survives" do
    name = :"slots_temp_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        Supervisor.child_spec({Slots, name: name, max: 1}, id: name, restart: :temporary)
      )

    test_pid = self()

    holder = hold(name, test_pid)
    assert_receive {:holding, _}

    caller =
      spawn(fn ->
        result = Slots.run(name, 5_000, fn -> :ran end)
        send(test_pid, {:caller_done, result})
        Process.sleep(:infinity)
      end)

    await_queued(name, 1)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    assert_receive {:caller_done, {:ok, :ran, _}}, 2_000
    assert Process.alive?(caller)
    Process.exit(caller, :kill)
    Process.exit(holder, :kill)
  end

  test "without a server the function runs unbounded" do
    assert {:ok, :ok, 0} = Slots.run(:no_such_slots, 1_000, fn -> :ok end)
  end
end
