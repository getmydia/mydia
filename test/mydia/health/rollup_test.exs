defmodule Mydia.Health.RollupTest do
  use ExUnit.Case, async: true

  alias Mydia.Health.Rollup

  describe "from_status_map/1" do
    test "returns state :none when map is empty or all disabled" do
      assert %Rollup{state: :none, total: 0} = Rollup.from_status_map(%{})

      status_map = %{
        "c1" => %{status: :disabled},
        "c2" => %{status: :disabled}
      }

      assert %Rollup{state: :none, total: 0} = Rollup.from_status_map(status_map)
    end

    test "returns state :checking when all enabled entries are unknown" do
      status_map = %{
        "c1" => %{status: :unknown},
        "c2" => %{status: :unknown},
        "c3" => %{status: :disabled}
      }

      rollup = Rollup.from_status_map(status_map)
      assert rollup.state == :checking
      assert rollup.total == 2
      assert rollup.unknown == 2
      assert Rollup.label(rollup) == "Checking…"
    end

    test "returns state :down when all enabled entries are unhealthy" do
      status_map = %{
        "c1" => %{status: :unhealthy},
        "c2" => %{status: :unhealthy}
      }

      rollup = Rollup.from_status_map(status_map)
      assert rollup.state == :down
      assert rollup.total == 2
      assert rollup.unhealthy == 2
      assert Rollup.label(rollup) == "0/2 healthy"
    end

    test "returns state :degraded when at least one entry is unhealthy" do
      status_map = %{
        "c1" => %{status: :healthy},
        "c2" => %{status: :unhealthy}
      }

      rollup = Rollup.from_status_map(status_map)
      assert rollup.state == :degraded
      assert rollup.total == 2
      assert rollup.healthy == 1
      assert rollup.unhealthy == 1
      assert Rollup.label(rollup) == "1/2 healthy"
    end

    test "returns state :ok when all entries are healthy" do
      status_map = %{
        "c1" => %{status: :healthy},
        "c2" => %{status: :healthy}
      }

      rollup = Rollup.from_status_map(status_map)
      assert rollup.state == :ok
      assert rollup.total == 2
      assert rollup.healthy == 2
      assert Rollup.label(rollup) == "2/2 healthy"
    end

    test "includes unknown checking count in label when state is not :checking" do
      status_map = %{
        "c1" => %{status: :healthy},
        "c2" => %{status: :healthy},
        "c3" => %{status: :unknown}
      }

      rollup = Rollup.from_status_map(status_map)
      assert rollup.state == :ok
      assert rollup.total == 3
      assert rollup.healthy == 2
      assert rollup.unknown == 1
      assert Rollup.label(rollup) == "2/3 healthy, 1 checking"
    end
  end
end
