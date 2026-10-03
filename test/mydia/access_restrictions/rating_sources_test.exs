defmodule Mydia.AccessRestrictions.RatingSourcesTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0]
  import Mydia.RelayStubs

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.Add
  alias Mydia.MediaRequests
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, config: relay_config(bypass)}
  end

  describe "requests under an age limit (#1000)" do
    setup do
      requester = user_fixture()
      scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))
      %{scope: scope, requester: requester}
    end

    test "a PG movie can be requested", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, title: "Lantern Vale", certification: "PG")

      assert {:ok, _} =
               MediaRequests.create_request(
                 ctx.scope,
                 request_attrs(id, "Lantern Vale", ctx),
                 config: ctx.config
               )
    end

    test "an R movie is refused", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, title: "Crimson Ledger", certification: "R")

      assert {:error, :restricted} =
               MediaRequests.create_request(
                 ctx.scope,
                 request_attrs(id, "Crimson Ledger", ctx),
                 config: ctx.config
               )
    end

    test "an unrated movie is refused", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, title: "Blank Placard")

      assert {:error, :restricted} =
               MediaRequests.create_request(
                 ctx.scope,
                 request_attrs(id, "Blank Placard", ctx),
                 config: ctx.config
               )
    end
  end

  describe "Add.resolve_attrs/4 stores a rating" do
    test "movie", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, certification: "PG-13")

      assert {:ok, attrs} = Add.resolve_attrs({:tmdb, id}, :movie, ctx.config)
      assert attrs.metadata.content_rating == "PG-13"
    end

    test "tv show from a TVDB ref with only a TMDB rating", ctx do
      tvdb_id = unique_provider_id()
      tmdb_id = unique_provider_id()

      on_exit(fn ->
        Mydia.Metadata.Cache.delete("tvdb_tmdb_rating:#{tmdb_id}")
        Mydia.Metadata.Cache.delete("tvdb_tmdb_videos:#{tmdb_id}:en-US")
      end)

      stub_tvdb_series(ctx.bypass, tvdb_id, remote_tmdb_id: tmdb_id)
      stub_tmdb_tv(ctx.bypass, tmdb_id, certification: "TV-Y7")

      assert {:ok, attrs} = Add.resolve_attrs({:tvdb, tvdb_id}, :tv_show, ctx.config)
      assert attrs.metadata.content_rating == "TV-Y7"
    end

    test "an added movie gets a content_rating_age", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, title: "Copper Tide", certification: "PG")

      {:ok, attrs} = Add.resolve_attrs({:tmdb, id}, :movie, ctx.config)

      {:ok, item} =
        Add.from_attrs(Scope.unrestricted(), attrs, ctx.config, skip_episode_refresh: true)

      assert Media.get_media_item!(Scope.unrestricted(), item.id).content_rating_age == 8
    end
  end

  test "the preview modal's detail fetch carries the rating", ctx do
    id = unique_provider_id()
    stub_tmdb_movie(ctx.bypass, id, certification: "PG")

    assert {:ok, md} = MediaAddHelpers.fetch_detail_metadata({:tmdb, id}, :movie, ctx.config)
    assert md.content_rating == "PG"
  end

  defp request_attrs(id, title, ctx),
    do: %{media_type: "movie", title: title, tmdb_id: id, requester_id: ctx.requester.id}
end
