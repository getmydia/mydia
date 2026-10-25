defmodule Mydia.Downloads.PriorAttemptsTest do
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.PriorAttempt
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  defp result(attrs \\ []) do
    n = System.unique_integer([:positive])

    struct!(
      SearchResult,
      Enum.into(attrs, %{
        title: "Release #{n}",
        size: 1_000_000,
        seeders: 1,
        leechers: 0,
        indexer: "Indexer",
        guid: "guid-#{n}",
        download_url: "https://example.test/#{n}.torrent"
      })
    )
  end

  defp fail!(download, message, updated_at \\ DateTime.utc_now()) do
    Repo.update_all(from(d in Download, where: d.id == ^download.id),
      set: [error_message: message, updated_at: DateTime.truncate(updated_at, :second)]
    )
  end

  test "a failed download for the item matches by URL" do
    item = media_item_fixture(%{type: "movie"})
    res = result()
    d = download_fixture(%{media_item_id: item.id, download_url: res.download_url})
    fail!(d, "boom")

    assert %{} = map = Downloads.prior_attempts_for_results([res], item, nil)
    assert %PriorAttempt{kind: :failed, reason: "boom", at: %DateTime{}} = map[res.download_url]
  end

  test "downloads without an error are ignored and unmatched results are absent" do
    item = media_item_fixture(%{type: "movie"})
    res = result()
    other = result()
    download_fixture(%{media_item_id: item.id, download_url: res.download_url})

    assert Downloads.prior_attempts_for_results([res, other], item, nil) == %{}
  end

  test "results without a download_url are skipped" do
    item = media_item_fixture(%{type: "movie"})
    assert Downloads.prior_attempts_for_results([result(download_url: nil)], item, nil) == %{}
  end

  test "another episode's failure does not leak into an episode context" do
    show = media_item_fixture(%{type: "tv_show"})
    ep1 = episode_fixture(%{media_item_id: show.id})
    ep2 = episode_fixture(%{media_item_id: show.id})
    res = result()

    d =
      download_fixture(%{
        media_item_id: show.id,
        episode_id: ep1.id,
        download_url: res.download_url
      })

    fail!(d, "bad")

    assert Downloads.prior_attempts_for_results([res], show, %{type: :episode, episode_id: ep2.id}) ==
             %{}

    assert %{} =
             map =
             Downloads.prior_attempts_for_results([res], show, %{
               type: :episode,
               episode_id: ep1.id
             })

    assert map[res.download_url].kind == :failed
  end

  test "season context only matches season packs of that season" do
    show = media_item_fixture(%{type: "tv_show"})
    s2 = result()
    s3 = result()
    plain = result()

    for {res, meta} <- [
          {s2, %{season_pack: true, season_number: 2}},
          {s3, %{season_pack: true, season_number: 3}},
          {plain, %{}}
        ] do
      d =
        download_fixture(%{
          media_item_id: show.id,
          download_url: res.download_url,
          metadata: meta
        })

      fail!(d, "bad")
    end

    map =
      Downloads.prior_attempts_for_results([s2, s3, plain], show, %{
        type: :season,
        season_number: 2
      })

    assert Map.keys(map) == [s2.download_url]
  end

  test "blacklist matches by indexer and guid, and is not scoped to the item" do
    item = media_item_fixture(%{type: "movie"})
    res = result(indexer: "MyIndexer", guid: "abc")
    {:ok, _} = Blacklists.add("myindexer", "abc", "T", "stalled")

    map = Downloads.prior_attempts_for_results([res], item, nil)
    assert %PriorAttempt{kind: :blacklisted, reason: "stalled"} = map[res.download_url]
  end

  test "blacklist matches a magnet by infohash across indexers" do
    item = media_item_fixture(%{type: "movie"})
    hash = String.duplicate("ab", 20)
    res = result(download_url: "magnet:?xt=urn:btih:#{hash}", guid: "other-guid")
    {:ok, _} = Blacklists.add("elsewhere", "g1", "T", "par fail", info_hash: hash)

    map = Downloads.prior_attempts_for_results([res], item, nil)
    assert %PriorAttempt{kind: :blacklisted, reason: "par fail"} = map[res.download_url]
  end

  test "an expired ban is ignored" do
    item = media_item_fixture(%{type: "movie"})
    res = result(indexer: "idx", guid: "old")
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    {:ok, _} = Blacklists.add("idx", "old", "T", "x", expires_at: past)

    assert Downloads.prior_attempts_for_results([res], item, nil) == %{}
    assert Repo.aggregate(ReleaseBlacklist, :count) == 1
  end

  test "the newest failure per URL wins" do
    item = media_item_fixture(%{type: "movie"})
    res = result()
    old = download_fixture(%{media_item_id: item.id, download_url: res.download_url})
    new = download_fixture(%{media_item_id: item.id, download_url: res.download_url})
    now = DateTime.utc_now()
    fail!(old, "older", DateTime.add(now, -600, :second))
    fail!(new, "newer", now)

    map = Downloads.prior_attempts_for_results([res], item, nil)
    assert map[res.download_url].reason == "newer"
  end

  test "blacklist beats a failed download for the same URL" do
    item = media_item_fixture(%{type: "movie"})
    res = result(indexer: "idx", guid: "both")
    d = download_fixture(%{media_item_id: item.id, download_url: res.download_url})
    fail!(d, "failed")
    {:ok, _} = Blacklists.add("idx", "both", "T", "banned")

    map = Downloads.prior_attempts_for_results([res], item, nil)
    assert %PriorAttempt{kind: :blacklisted, reason: "banned"} = map[res.download_url]
  end
end
