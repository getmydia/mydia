defmodule MydiaWeb.MediaLive.Show.RailLibraryTargetTest do
  @moduledoc """
  #458: a library chosen from a rail card must be the library the title lands
  in.

  Asserted against `perform_add/4` rather than a rendered click. The add path
  calls the uncached `Metadata.fetch_by_id/3` with the LiveView's
  `metadata_config`, which `show.ex` builds from `default_relay_config/0`, and
  that reads global env. There is no seam to inject a Bypass config through
  `live/2`, and a test must not mutate global env to make one.
  """

  # Not async: these insert library paths, which candidate_libraries/1 reads
  # back through the shared sandbox connection.
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts.Scope
  alias Mydia.Library.TargetResolver
  alias Mydia.Metadata
  alias Mydia.Repo
  alias MydiaWeb.MediaLive.Show.FranchiseEvents
  alias MydiaWeb.MediaLive.Show.RecommendationEvents

  # Serves the added title's metadata from Bypass. Unlike the cache helpers
  # this config is handed straight to perform_add, because the add path does
  # not go through the ETS cache at all.
  defp bypass_relay_config(tmdb_id, title) do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => title,
        "release_date" => "2005-01-01",
        "belongs_to_collection" => nil
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    relay = Metadata.default_relay_config()
    %{relay | base_url: "http://localhost:#{bypass.port}"}
  end

  describe "recommendations rail" do
    test "adds into the chosen library rather than the resolved default" do
      _default = library_path_fixture(%{path: "/media/rec-default", type: "movies"})
      chosen = library_path_fixture(%{path: "/media/rec-chosen", type: "movies"})

      source = media_item_fixture(%{type: "movie", title: "Source", year: 2001})
      added_tmdb_id = unique_provider_id()
      config = bypass_relay_config(added_tmdb_id, "Recommended")

      assert {:ok, added} =
               RecommendationEvents.perform_add(
                 Scope.unrestricted(),
                 source,
                 added_tmdb_id,
                 config,
                 library_path_id: to_string(chosen.id)
               )

      assert Repo.reload!(added).library_path_id == chosen.id
    end

    test "falls back to normal resolution when no library was chosen" do
      default = library_path_fixture(%{path: "/media/rec-only", type: "movies"})

      source = media_item_fixture(%{type: "movie", title: "Source", year: 2001})
      added_tmdb_id = unique_provider_id()
      config = bypass_relay_config(added_tmdb_id, "Recommended")

      assert {:ok, added} =
               RecommendationEvents.perform_add(
                 Scope.unrestricted(),
                 source,
                 added_tmdb_id,
                 config
               )

      # No library_path_id is written at add time when no choice was made:
      # `library_path_opts/2` returns `{:ok, []}` for that case, same as
      # before this change. "Normal resolution" is dynamic, performed by
      # Mydia.Library.TargetResolver wherever content for the item is placed
      # (import, rematch, the detail page), not persisted eagerly here.
      refute Repo.reload!(added).library_path_id

      assert {:ok, resolved, _reason} = TargetResolver.resolve(added)
      assert resolved.id == default.id
    end
  end

  describe "collection strip" do
    test "adds into the chosen library rather than the resolved default" do
      _default = library_path_fixture(%{path: "/media/fr-default", type: "movies"})
      chosen = library_path_fixture(%{path: "/media/fr-chosen", type: "movies"})

      source = media_item_fixture(%{type: "movie", title: "First", year: 2001})
      added_tmdb_id = unique_provider_id()
      config = bypass_relay_config(added_tmdb_id, "Second")

      assert {:ok, added} =
               FranchiseEvents.perform_add(
                 Scope.unrestricted(),
                 source,
                 added_tmdb_id,
                 config,
                 library_path_id: to_string(chosen.id)
               )

      assert Repo.reload!(added).library_path_id == chosen.id
    end

    test "falls back to normal resolution when no library was chosen" do
      default = library_path_fixture(%{path: "/media/fr-only", type: "movies"})

      source = media_item_fixture(%{type: "movie", title: "First", year: 2001})
      added_tmdb_id = unique_provider_id()
      config = bypass_relay_config(added_tmdb_id, "Second")

      assert {:ok, added} =
               FranchiseEvents.perform_add(Scope.unrestricted(), source, added_tmdb_id, config)

      # See the mirrored comment in the recommendations describe block above:
      # no library_path_id is written at add time when no choice was made.
      refute Repo.reload!(added).library_path_id

      assert {:ok, resolved, _reason} = TargetResolver.resolve(added)
      assert resolved.id == default.id
    end
  end
end
