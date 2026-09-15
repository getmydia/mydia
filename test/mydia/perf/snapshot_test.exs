defmodule Mydia.Perf.SnapshotTest do
  use ExUnit.Case, async: true

  alias Mydia.Perf.Snapshot

  @key {"perf_test.work.stop.duration", %{kind: "a"}}

  defp values(buckets, sum), do: Map.merge(%{infinity: 0, sum: sum}, buckets)

  describe "normalize/1" do
    test "Peep not running is an empty snapshot" do
      assert Snapshot.normalize(nil) == %{}
    end

    test "keys distributions by dotted name and tags, dropping other metric types" do
      # Built in the test body: metric structs hold anonymous functions, which a
      # module attribute cannot store.
      distribution = Telemetry.Metrics.distribution("perf_test.work.stop.duration", tags: [:kind])
      counter = Telemetry.Metrics.counter("perf_test.work.stop.count")

      peep = %{
        distribution => %{%{kind: "a"} => values(%{"1.0" => 2}, 3)},
        counter => %{%{} => 7}
      }

      assert Snapshot.normalize(peep) == %{@key => values(%{"1.0" => 2}, 3)}
    end
  end

  describe "deltas/2" do
    test "against an empty baseline, the non-empty buckets and the sum" do
      current = %{@key => values(%{"1.0" => 2, "1.222222" => 0}, 3)}

      assert Snapshot.deltas(current, %{}) == [
               %{
                 metric: "perf_test.work.stop.duration",
                 tags: "kind=a",
                 count: 2,
                 sum_us: 3,
                 buckets: %{"1.0" => 2}
               }
             ]
    end

    test "subtracts the baseline and omits keys with nothing new" do
      unchanged = {"perf_test.other.stop.duration", %{}}
      baseline = %{@key => values(%{"1.0" => 2}, 3), unchanged => values(%{"1.0" => 1}, 1)}

      current = %{
        @key => values(%{"1.0" => 5, "2.0" => 1}, 10),
        unchanged => values(%{"1.0" => 1}, 1)
      }

      assert [%{tags: "kind=a", count: 4, sum_us: 7, buckets: %{"1.0" => 3, "2.0" => 1}}] =
               Snapshot.deltas(current, baseline)
    end

    test "above-max counts are encoded as inf" do
      current = %{@key => %{"1.0" => 0, infinity: 2, sum: 9_000_000_000}}

      assert [%{count: 2, buckets: %{"inf" => 2}}] = Snapshot.deltas(current, %{})
    end

    test "a baseline ahead of the snapshot (Peep restarted) counts the snapshot from zero" do
      baseline = %{@key => values(%{"1.0" => 9}, 90)}
      current = %{@key => values(%{"1.0" => 2}, 3)}

      assert [%{count: 2, sum_us: 3}] = Snapshot.deltas(current, baseline)
    end
  end

  describe "encode_tags/1" do
    test "sorts keys and stringifies values" do
      assert Snapshot.encode_tags(%{view: "MydiaWeb.MediaLive.Index", connected: true}) ==
               "connected=true,view=MydiaWeb.MediaLive.Index"
    end

    test "no tags" do
      assert Snapshot.encode_tags(%{}) == ""
    end
  end
end
