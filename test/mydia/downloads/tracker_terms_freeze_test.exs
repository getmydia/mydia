defmodule Mydia.Downloads.TrackerTermsFreezeTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.{Download, History, Queue}
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Repo
  alias Mydia.Settings.TrackerRuleConfigs

  defp result(attrs) do
    struct!(
      SearchResult,
      Map.merge(
        %{
          title: "Velvet.Orchard.2031.1080p.WEB-DL",
          size: 1_000,
          seeders: 10,
          leechers: 1,
          download_url: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
          indexer: "Velvet Lantern",
          download_protocol: :torrent
        },
        attrs
      )
    )
  end

  defp grab(search_result) do
    {:ok, download} =
      History.create_download(%{
        indexer: search_result.indexer,
        title: search_result.title,
        download_url: search_result.download_url,
        metadata: Queue.build_download_metadata(search_result)
      })

    Repo.get!(Download, download.id)
  end

  test "the effective terms, overrides applied, are frozen on the download" do
    {:ok, rule} =
      TrackerRuleConfigs.create(%{tracker: "velvet lantern", seed_ratio: 2.0})

    download =
      grab(
        result(%{
          terms: %TrackerTerms{
            minimum_ratio: 1.0,
            minimum_seed_time: 7200,
            download_volume_factor: 0.0,
            private?: true
          }
        })
      )

    frozen = %{
      "private" => true,
      "minimum_ratio" => 2.0,
      "minimum_seed_time" => 7200,
      "download_volume_factor" => 0.0,
      "upload_volume_factor" => nil
    }

    assert download.metadata["tracker_terms"] == frozen

    {:ok, _} = TrackerRuleConfigs.update(rule, %{seed_ratio: 5.0, seed_time: 10})

    assert Repo.get!(Download, download.id).metadata["tracker_terms"] == frozen
  end

  test "a rule alone gives a tracker that reported nothing frozen terms" do
    {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Velvet Lantern", private: true})

    assert %{"private" => true, "minimum_ratio" => nil} =
             grab(result(%{})).metadata["tracker_terms"]
  end

  test "a manual grab through Downloads.grab_async/2 freezes the terms" do
    Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Velvet Lantern", seed_time: 60})
    movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie"})

    {:ok, download} =
      Mydia.Downloads.grab_async(result(%{terms: %TrackerTerms{private?: true}}),
        media_item_id: movie.id,
        manual: true
      )

    # No client is configured, so the background task fails the grab; wait for
    # it so it does not outlive the test.
    assert_receive {:grab_failed, %{download_id: id}} when id == download.id, 2_000

    assert %{"private" => true, "minimum_seed_time" => 3600} =
             Repo.get!(Download, download.id).metadata["tracker_terms"]
  end

  test "no reported terms and no rule store no tracker terms" do
    refute Map.has_key?(grab(result(%{})).metadata, "tracker_terms")
  end
end
