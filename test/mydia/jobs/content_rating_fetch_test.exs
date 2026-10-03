defmodule Mydia.Jobs.ContentRatingFetchTest do
  use Mydia.DataCase, async: false

  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0]
  import Mydia.RelayStubs

  alias Mydia.Accounts.Scope
  alias Mydia.Jobs.ContentRatingFetch
  alias Mydia.Media

  setup do
    bypass = Bypass.open()
    Application.put_env(:mydia, :content_rating_fetch_config, relay_config(bypass))
    on_exit(fn -> Application.delete_env(:mydia, :content_rating_fetch_config) end)
    %{bypass: bypass}
  end

  test "fills an unrated movie from TMDB", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_movie(bypass, id, certification: "PG-13")
    item = insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Quiet Orchard"})

    assert :ok = run()

    reloaded = Media.get_media_item!(Scope.unrestricted(), item.id)
    assert reloaded.metadata.content_rating == "PG-13"
    assert reloaded.content_rating_age == 13
  end

  test "fills a TVDB-sourced show through its TMDB id", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_tv(bypass, id, certification: "TV-Y7")

    item =
      insert(:media_item,
        type: "tv_show",
        tmdb_id: id,
        tvdb_id: unique_provider_id(),
        metadata: %{title: "Moss Lantern"}
      )

    assert :ok = run()
    assert Media.get_media_item!(Scope.unrestricted(), item.id).content_rating_age == 7
  end

  test "leaves a row that already stores a rating alone", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_movie(bypass, id, certification: "R", test_pid: self())

    insert(:media_item,
      type: "movie",
      tmdb_id: id,
      metadata: %{title: "Odd Rating", content_rating: "NR"}
    )

    assert :ok = run()
    refute_received {:relay_hit, _, _}
  end

  test "skips rows with no TMDB id and survives a relay error", %{bypass: bypass} do
    id = unique_provider_id()
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", &Plug.Conn.resp(&1, 500, "boom"))
    insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Broken Feed"})

    insert(:media_item,
      type: "tv_show",
      tmdb_id: nil,
      tvdb_id: unique_provider_id(),
      metadata: %{title: "No Cross Ref"}
    )

    assert :ok = run()
  end

  test "is idempotent", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_movie(bypass, id, certification: "G", test_pid: self())
    insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Twice Told"})

    :ok = run()
    assert_received {:relay_hit, _, _}
    :ok = run()
    refute_received {:relay_hit, _, _}
  end

  test "enqueue_once never raises" do
    assert ContentRatingFetch.enqueue_once() == :ok
  end

  defp run, do: ContentRatingFetch.perform(%Oban.Job{args: %{"delay_ms" => 0}})
end
