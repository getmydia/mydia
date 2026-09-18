defmodule Mydia.Indexers.IdentityShadowTest do
  use Mydia.DataCase, async: true

  alias Mydia.Events
  alias Mydia.Indexers.{IdentityShadow, QualityParser, SearchResult}
  alias Mydia.Indexers.ReleaseIdentity.Target
  alias Mydia.Media.MediaItem

  @target %Target{type: :movie, year: 2031, keys: ["lantern"]}
  @junk "2031-05-12 Lantern Vale (Harbor Chapter 1 Arrival) 1080p.mkv"
  @real "Lantern.2031.1080p.WEB-DL.x264-GROUP"

  defp result(title, seeders) do
    %SearchResult{
      title: title,
      size: 2_000_000_000,
      seeders: seeders,
      leechers: 1,
      download_url: "magnet:?xt=urn:btih:" <> Base.encode16(:erlang.md5(title)),
      indexer: "Test Indexer",
      quality: QualityParser.parse(title),
      published_at: DateTime.utc_now()
    }
  end

  defp opts,
    do: [media_type: :movie, min_seeders: 0, expected_title: "Lantern", identity_target: @target]

  defp movie, do: %MediaItem{id: Ecto.UUID.generate(), title: "Lantern", type: "movie"}

  describe "compare/2" do
    test "is nil when both gates pick the same release" do
      assert IdentityShadow.compare([result(@real, 50), result(@junk, 5)], opts()) == nil
    end

    test "describes the disagreement when the title gate picks a release the identity check rejects" do
      diff = IdentityShadow.compare([result(@junk, 50), result(@real, 5)], opts())

      assert diff["legacy_pick"] == @junk
      assert diff["legacy_pick_verdict"] == "mismatch: title"
      assert diff["exact_pick"] == @real
      assert diff["legacy_candidates"] == 2
      assert diff["exact_candidates"] == 1
      assert diff["rejections"] == [%{"title" => @junk, "reason" => "title"}]
    end

    test "reports no exact pick when the identity check rejects everything" do
      diff = IdentityShadow.compare([result(@junk, 50)], opts())

      assert diff["legacy_pick"] == @junk
      assert diff["exact_pick"] == nil
    end

    test "is nil without an identity target" do
      assert IdentityShadow.compare([result(@junk, 50)], Keyword.delete(opts(), :identity_target)) ==
               nil
    end
  end

  describe "observe/5" do
    test "records a search.identity_shadow event on disagreement" do
      assert :ok =
               IdentityShadow.observe(movie(), [result(@junk, 50)], opts(), %{
                 "query" => "Lantern 2031"
               })

      assert [event] = Events.list_events(type: "search.identity_shadow")
      assert event.metadata["query"] == "Lantern 2031"
      assert event.metadata["legacy_pick"] == @junk
      assert event.metadata["exact_pick"] == nil
    end

    test "records nothing when the gates agree" do
      assert :ok =
               IdentityShadow.observe(movie(), [result(@real, 50)], opts(), %{
                 "query" => "Lantern 2031"
               })

      assert Events.list_events(type: "search.identity_shadow") == []
    end
  end
end
