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

  test "a relay error fails the job so Oban retries, and leaves the row unrated", %{
    bypass: bypass
  } do
    id = unique_provider_id()
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", &Plug.Conn.resp(&1, 500, "boom"))
    broken = insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Broken Feed"})

    no_ref =
      insert(:media_item,
        type: "tv_show",
        tmdb_id: nil,
        tvdb_id: unique_provider_id(),
        metadata: %{title: "No Cross Ref"}
      )

    ok_id = unique_provider_id()
    stub_tmdb_movie(bypass, ok_id, certification: "PG", test_pid: self())
    fine = insert(:media_item, type: "movie", tmdb_id: ok_id, metadata: %{title: "Fine Feed"})

    result = ExUnit.CaptureLog.with_log(fn -> run() end) |> elem(0)

    assert {:error, {:relay_errors, 1}} = result
    scope = Scope.unrestricted()
    assert Media.get_media_item!(scope, broken.id).content_rating_age == nil
    assert Media.get_media_item!(scope, no_ref.id).content_rating_age == nil
    # The walk finished: the healthy row was still filled.
    assert Media.get_media_item!(scope, fine.id).content_rating_age == 8
    refute_received {:relay_hit, "/tmdb/tv/shows/" <> _, _}
  end

  test "a failed write fails the job so Oban retries instead of retiring it", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_movie(bypass, id, certification: "PG-13")

    # A movie row without a year fails MediaItem.changeset/2 on every update.
    item =
      insert(:media_item, type: "movie", year: nil, tmdb_id: id, metadata: %{title: "Yearless"})

    {result, log} = ExUnit.CaptureLog.with_log(fn -> run() end)

    assert {:error, {:relay_errors, 1}} = result
    assert log =~ "could not store rating"
    assert Media.get_media_item!(Scope.unrestricted(), item.id).content_rating_age == nil
  end

  test "a TMDB answer with no certification is not an error", %{bypass: bypass} do
    id = unique_provider_id()
    stub_tmdb_movie(bypass, id, test_pid: self())
    item = insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Unrated Dusk"})

    assert :ok = run()
    assert_received {:relay_hit, _, _}
    assert Media.get_media_item!(Scope.unrestricted(), item.id).content_rating_age == nil
  end

  test "walks past the first batch", %{bypass: bypass} do
    items =
      for n <- 1..5 do
        id = unique_provider_id()
        stub_tmdb_movie(bypass, id, certification: "R")
        insert(:media_item, type: "movie", tmdb_id: id, metadata: %{title: "Batch Fixture #{n}"})
      end

    assert :ok =
             ContentRatingFetch.perform(%Oban.Job{args: %{"delay_ms" => 0, "batch_size" => 2}})

    scope = Scope.unrestricted()
    assert Enum.all?(items, &(Media.get_media_item!(scope, &1.id).content_rating_age == 17))
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
