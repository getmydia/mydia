defmodule Mydia.Indexers.TrackerSightingsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Indexers.TrackerSightings
  alias Mydia.Indexers.TrackerSightings.{Row, Sighting}
  alias Mydia.Repo
  alias Mydia.Settings.{TrackerRuleConfig, TrackerRuleConfigs}

  @now ~U[2031-06-01 12:00:00Z]

  defp result(indexer, terms) do
    SearchResult.new(
      title: "Velvet.Orchard.2031.1080p.WEB-DL",
      size: 1,
      seeders: 1,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:abc",
      indexer: indexer,
      terms: terms
    )
  end

  defp seen(tracker, days_ago, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Sighting,
        Map.merge(
          %{
            tracker: tracker,
            tracker_key: TrackerRuleConfig.key(tracker),
            last_seen_at: DateTime.add(@now, -days_ago * 86_400)
          },
          attrs
        )
      )
    )
  end

  defp row(rows, key), do: Enum.find(rows, &(&1.key == key))

  describe "record/2" do
    test "two results from one tracker make one row with what either reported" do
      :ok =
        TrackerSightings.record(
          [
            result("Velvet Lantern", %TrackerTerms{minimum_ratio: 1.0}),
            result("velvet lantern", %TrackerTerms{private?: true, minimum_seed_time: 3600}),
            result("Open Reel", nil)
          ],
          @now
        )

      assert [open, velvet] = Repo.all(from s in Sighting, order_by: s.tracker_key)
      assert %Sighting{tracker_key: "open reel", private: nil, last_seen_at: @now} = open

      assert %Sighting{
               tracker: "Velvet Lantern",
               private: true,
               minimum_ratio: 1.0,
               minimum_seed_time: 3600
             } = velvet
    end

    test "a later sighting without a value keeps the earlier one" do
      :ok =
        TrackerSightings.record(
          [result("Velvet Lantern", %TrackerTerms{minimum_ratio: 1.0})],
          @now
        )

      later = DateTime.add(@now, 60)

      :ok =
        TrackerSightings.record([result("Velvet Lantern", %TrackerTerms{private?: true})], later)

      assert [%Sighting{minimum_ratio: 1.0, private: true, last_seen_at: ^later}] =
               Repo.all(Sighting)
    end
  end

  describe "list_trackers/1" do
    test "lists recent trackers and every rule with effective terms" do
      seen("Velvet Lantern", 2, %{minimum_ratio: 1.0, private: true})
      seen("Faded Reel", 45)

      {:ok, _} =
        TrackerRuleConfigs.create(%{tracker: "Velvet Lantern", seed_ratio: 2.0})

      rows = TrackerSightings.list_trackers(@now)

      assert Enum.map(rows, & &1.key) == ["velvet lantern"]

      assert %Row{
               tracker: "Velvet Lantern",
               reported: %TrackerTerms{minimum_ratio: 1.0, private?: true},
               effective: %TrackerTerms{minimum_ratio: 2.0, private?: true},
               rule: %TrackerRuleConfig{},
               stale?: false
             } = row(rows, "velvet lantern")
    end

    test "flags a rule whose tracker matched nothing in 30 days" do
      old_rule(%{tracker: "Faded Reel", seed_ratio: 1.0})
      seen("Faded Reel", 45)

      assert %Row{stale?: true, last_seen_at: %DateTime{}} =
               row(TrackerSightings.list_trackers(@now), "faded reel")
    end

    test "flags a rule for a tracker never seen" do
      old_rule(%{tracker: "Ghost Reel", seed_ratio: 1.0})

      assert %Row{stale?: true, last_seen_at: nil} =
               row(TrackerSightings.list_trackers(@now), "ghost reel")
    end

    test "a tracker seen ten days ago is not stale" do
      old_rule(%{tracker: "Velvet Lantern", seed_ratio: 1.0})
      seen("Velvet Lantern", 10)
      refute row(TrackerSightings.list_trackers(@now), "velvet lantern").stale?
    end

    test "a grab from the tracker in 30 days keeps its rule fresh" do
      old_rule(%{tracker: "Copper Reel", seed_ratio: 1.0})

      Repo.insert!(%Download{
        title: "Velvet.Orchard.2031.1080p.WEB-DL",
        indexer: "COPPER REEL",
        inserted_at: DateTime.add(@now, -5 * 86_400),
        updated_at: @now
      })

      refute row(TrackerSightings.list_trackers(@now), "copper reel").stale?
    end

    test "a rule added in the last 30 days is not stale yet" do
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "New Reel", seed_ratio: 1.0})
      refute row(TrackerSightings.list_trackers(DateTime.utc_now()), "new reel").stale?
    end
  end

  defp old_rule(attrs) do
    {:ok, rule} = TrackerRuleConfigs.create(attrs)
    old = DateTime.add(@now, -60 * 86_400)
    rule |> Ecto.Changeset.change(inserted_at: old, updated_at: old) |> Repo.update!()
  end
end
