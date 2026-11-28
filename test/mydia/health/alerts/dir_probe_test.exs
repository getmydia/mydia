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

  test "without a table it checks inline" do
    assert DirProbe.dir?("/nonexistent-b", table: :no_such_dir_probe_table) == false
  end
end
