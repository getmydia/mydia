defmodule Mydia.Health.Alerts.DirProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Health.Alerts.DirProbe

  setup do
    table = :ets.new(:dir_probe_test, [:set, :public])
    %{table: table}
  end

  @tag :tmp_dir
  test "an existing folder is true", %{table: table, tmp_dir: dir} do
    assert DirProbe.dir?(dir, table: table) == true
  end

  test "a missing folder is false", %{table: table} do
    assert DirProbe.dir?("/nonexistent-dir-probe-test", table: table) == false
  end

  test "a check that does not answer in time is :timeout", %{table: table} do
    check = fn _ -> Process.sleep(:infinity) end
    assert DirProbe.dir?("/hung", table: table, timeout: 50, check: check) == :timeout
  end

  test "a still-stuck check is reused, not started again", %{table: table} do
    test_pid = self()

    check = fn _ ->
      send(test_pid, :probing)
      Process.sleep(:infinity)
    end

    opts = [table: table, timeout: 50, check: check]
    assert DirProbe.dir?("/hung", opts) == :timeout
    assert_receive :probing

    assert DirProbe.dir?("/hung", opts) == :timeout
    refute_receive :probing, 100
  end

  test "a finished check frees the path for the next probe", %{table: table} do
    assert DirProbe.dir?("/nonexistent-a", table: table) == false
    assert :ets.tab2list(table) == []
  end

  test "a check that finishes instantly never leaves an entry behind", %{table: table} do
    for _ <- 1..300 do
      assert DirProbe.dir?("/fast", table: table, check: fn _ -> false end) == false
      assert :ets.tab2list(table) == []
    end
  end

  test "a path already claimed by a live probe is not checked again", %{table: table} do
    holder = spawn(fn -> Process.sleep(:infinity) end)
    :ets.insert(table, {"/claimed", holder})
    test_pid = self()

    check = fn _ -> send(test_pid, :probing) end
    assert DirProbe.dir?("/claimed", table: table, timeout: 50, check: check) == :timeout
    refute_receive :probing, 50
  end

  test "a stale entry from a dead probe is replaced", %{table: table} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}
    :ets.insert(table, {"/stale", dead})

    assert DirProbe.dir?("/stale", table: table, check: fn _ -> true end) == true
    assert :ets.tab2list(table) == []
  end

  test "concurrent probes of one path start a single check", %{table: table} do
    test_pid = self()

    check = fn _ ->
      send(test_pid, :probing)
      Process.sleep(:infinity)
    end

    1..20
    |> Enum.map(fn _ ->
      Task.async(fn -> DirProbe.dir?("/race", table: table, timeout: 100, check: check) end)
    end)
    |> Task.await_many()

    assert_receive :probing
    refute_receive :probing, 50
  end

  test "without a table it checks inline" do
    assert DirProbe.dir?("/nonexistent-b", table: :no_such_dir_probe_table) == false
  end
end
