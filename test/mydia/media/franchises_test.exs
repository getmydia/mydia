defmodule Mydia.Media.FranchisesTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import ExUnit.CaptureLog

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.{Franchise, FranchiseEntry, Franchises}
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp movie_with_pointer(tmdb_id, collection_id, attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      type: "movie",
      title: "Movie #{tmdb_id}",
      year: 2001,
      tmdb_id: tmdb_id,
      metadata: %{
        "provider_id" => to_string(tmdb_id),
        "provider" => "metadata_relay",
        "media_type" => "movie",
        "title" => "Movie #{tmdb_id}",
        "collection_id" => collection_id,
        "collection_name" => "Collection #{collection_id}"
      }
    })
    |> media_item_fixture()
  end

  defp stub_collection(bypass, collection_id, parts) do
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{collection_id}:en-US") end)

    Bypass.stub(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      body = %{
        "id" => collection_id,
        "name" => "Collection #{collection_id}",
        "parts" => parts
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp part(id, title, date), do: %{"id" => id, "title" => title, "release_date" => date}

  describe "for_media_item/2 happy path" do
    test "marks owned, missing, and current entries", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      current = movie_with_pointer(801, cid)
      owned = movie_with_pointer(802, cid, %{title: "Sequel"})

      stub_collection(bypass, cid, [
        part(801, "First", "2001-01-01"),
        part(802, "Second", "2004-01-01"),
        part(803, "Third", "2007-01-01")
      ])

      assert {:ok, %Franchise{} = franchise} =
               Franchises.for_media_item(Scope.unrestricted(), current, config)

      assert franchise.name == "Collection #{cid}"
      assert franchise.total_count == 3
      assert franchise.owned_count == 2

      assert [first, second, third] = franchise.entries

      assert %FranchiseEntry{tmdb_id: 801, current?: true, in_library?: true} = first
      assert first.media_item_id == current.id
      assert first.year == 2001

      assert %FranchiseEntry{tmdb_id: 802, current?: false, in_library?: true} = second
      assert second.media_item_id == owned.id

      assert %FranchiseEntry{tmdb_id: 803, current?: false, in_library?: false} = third
      assert third.media_item_id == nil
    end

    test "carries the rating and the monitored flag onto each entry", %{
      bypass: bypass,
      config: config
    } do
      cid = System.unique_integer([:positive])
      current = movie_with_pointer(811, cid)
      _monitored = movie_with_pointer(812, cid, %{title: "Sequel", monitored: true})
      _unmonitored = movie_with_pointer(813, cid, %{title: "Threequel", monitored: false})

      stub_collection(bypass, cid, [
        Map.put(part(811, "First", "2001-01-01"), "vote_average", 7.4),
        Map.put(part(812, "Second", "2004-01-01"), "vote_average", 6.1),
        Map.put(part(813, "Third", "2007-01-01"), "vote_average", 5.2)
      ])

      assert {:ok, franchise} = Franchises.for_media_item(Scope.unrestricted(), current, config)

      by_id = Map.new(franchise.entries, &{&1.tmdb_id, &1})

      assert by_id[811].vote_average == 7.4
      assert by_id[812].vote_average == 6.1
      assert by_id[813].vote_average == 5.2

      # The struct defaults monitored to false, so a true here proves the value
      # came off the library join rather than the default.
      assert by_id[812].monitored == true
      assert by_id[813].monitored == false
    end

    test "a missing entry has no rating fallback and is not monitored", %{
      bypass: bypass,
      config: config
    } do
      cid = System.unique_integer([:positive])
      current = movie_with_pointer(821, cid)

      stub_collection(bypass, cid, [
        part(821, "First", "2001-01-01"),
        part(822, "Second", "2004-01-01")
      ])

      assert {:ok, franchise} = Franchises.for_media_item(Scope.unrestricted(), current, config)

      missing = Enum.find(franchise.entries, &(&1.tmdb_id == 822))

      assert missing.vote_average == nil
      assert missing.in_library? == false
      assert missing.monitored == false
    end

    test "orders entries by release date, undated last", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      current = movie_with_pointer(811, cid)

      stub_collection(bypass, cid, [
        %{"id" => 813, "title" => "Undated"},
        part(812, "Later", "2010-06-01"),
        part(811, "Earlier", "2002-03-01")
      ])

      assert {:ok, franchise} = Franchises.for_media_item(Scope.unrestricted(), current, config)
      assert Enum.map(franchise.entries, & &1.tmdb_id) == [811, 812, 813]
    end

    test "orders by full date, not by map term order on Date structs",
         %{bypass: bypass, config: config} do
      # Same year, descending day/month in the payload. A naive Enum.sort_by on
      # %Date{} compares :day before :month before :year and gets this wrong.
      cid = System.unique_integer([:positive])
      current = movie_with_pointer(821, cid)

      stub_collection(bypass, cid, [
        part(822, "December", "2005-12-01"),
        part(821, "January", "2005-01-30")
      ])

      assert {:ok, franchise} = Franchises.for_media_item(Scope.unrestricted(), current, config)
      assert Enum.map(franchise.entries, & &1.tmdb_id) == [821, 822]
    end
  end

  describe "for_media_item/2 pointer resolution" do
    test "falls back to a details fetch and persists the pointer",
         %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "No Pointer Yet",
          year: 2001,
          tmdb_id: 831,
          metadata: %{
            "provider_id" => "831",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "No Pointer Yet"
          }
        })

      on_exit(fn -> Cache.delete("fetch_by_id:metadata_relay:831:movie:en-US:") end)

      Bypass.stub(bypass, "GET", "/tmdb/movies/831", fn conn ->
        body = %{
          "id" => 831,
          "title" => "No Pointer Yet",
          "release_date" => "2001-01-01",
          "credits" => %{"cast" => [], "crew" => []},
          "belongs_to_collection" => %{"id" => cid, "name" => "Collection #{cid}"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      stub_collection(bypass, cid, [
        part(831, "First", "2001-01-01"),
        part(832, "Second", "2004-01-01")
      ])

      assert {:ok, %Franchise{}} = Franchises.for_media_item(Scope.unrestricted(), movie, config)

      reloaded = Media.get_media_item!(Scope.unrestricted(), movie.id)
      assert reloaded.metadata.collection_id == cid
      assert reloaded.metadata.collection_name == "Collection #{cid}"
    end

    test "persisting the pointer does not append a timeline event",
         %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "Quiet Persist",
          year: 2001,
          tmdb_id: 841,
          metadata: %{
            "provider_id" => "841",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Quiet Persist"
          }
        })

      on_exit(fn -> Cache.delete("fetch_by_id:metadata_relay:841:movie:en-US:") end)

      before_count = length(Mydia.Events.get_resource_events("media_item", movie.id, limit: 100))

      Bypass.stub(bypass, "GET", "/tmdb/movies/841", fn conn ->
        body = %{
          "id" => 841,
          "title" => "Quiet Persist",
          "release_date" => "2001-01-01",
          "credits" => %{"cast" => [], "crew" => []},
          "belongs_to_collection" => %{"id" => cid, "name" => "Collection #{cid}"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      stub_collection(bypass, cid, [
        part(841, "First", "2001-01-01"),
        part(842, "Second", "2004-01-01")
      ])

      assert {:ok, _} = Franchises.for_media_item(Scope.unrestricted(), movie, config)

      after_count = length(Mydia.Events.get_resource_events("media_item", movie.id, limit: 100))
      assert after_count == before_count
    end
  end

  describe "for_media_item/2 returns :none" do
    test "for a TV show", %{config: config} do
      show = media_item_fixture(%{type: "tv_show", title: "A Show", tmdb_id: 851, year: 2010})
      assert Franchises.for_media_item(Scope.unrestricted(), show, config) == :none
    end

    test "for a movie with no tmdb_id", %{config: config} do
      movie = media_item_fixture(%{type: "movie", title: "No Id", year: 2001})
      assert Franchises.for_media_item(Scope.unrestricted(), movie, config) == :none
    end

    test "when the movie has no franchise", %{bypass: bypass, config: config} do
      movie =
        media_item_fixture(%{
          type: "movie",
          title: "Standalone",
          year: 1999,
          tmdb_id: 861,
          metadata: %{
            "provider_id" => "861",
            "provider" => "metadata_relay",
            "media_type" => "movie",
            "title" => "Standalone"
          }
        })

      on_exit(fn -> Cache.delete("fetch_by_id:metadata_relay:861:movie:en-US:") end)

      Bypass.stub(bypass, "GET", "/tmdb/movies/861", fn conn ->
        body = %{
          "id" => 861,
          "title" => "Standalone",
          "release_date" => "1999-01-01",
          "credits" => %{"cast" => [], "crew" => []},
          "belongs_to_collection" => nil
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert Franchises.for_media_item(Scope.unrestricted(), movie, config) == :none
    end

    test "when the relay predates the endpoint", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      movie = movie_with_pointer(871, cid)

      on_exit(fn -> Cache.delete("collection:metadata_relay:#{cid}:en-US") end)

      Bypass.stub(bypass, "GET", "/tmdb/collections/#{cid}", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      # A 404 is the normal state of the world until the relay ships this
      # endpoint. It must not log a warning: an operator on a pre-upgrade
      # relay would otherwise get a fresh warning line on every movie page
      # view, indistinguishable from a genuinely broken relay.
      log =
        capture_log(fn ->
          assert Franchises.for_media_item(Scope.unrestricted(), movie, config) == :none
        end)

      refute log =~ "Franchise lookup failed"
    end

    @tag :capture_log
    test "when the relay is unreachable", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      movie = movie_with_pointer(881, cid)

      on_exit(fn -> Cache.delete("collection:metadata_relay:#{cid}:en-US") end)
      Bypass.down(bypass)

      assert Franchises.for_media_item(Scope.unrestricted(), movie, config) == :none
    end

    test "when the franchise has only one member", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      movie = movie_with_pointer(891, cid)

      stub_collection(bypass, cid, [part(891, "Only", "2001-01-01")])

      assert Franchises.for_media_item(Scope.unrestricted(), movie, config) == :none
    end
  end

  describe "for_media_item/2 malformed parts" do
    test "drops a part whose id is not an integer", %{bypass: bypass, config: config} do
      cid = System.unique_integer([:positive])
      movie = movie_with_pointer(901, cid)

      stub_collection(bypass, cid, [
        part(901, "First", "2001-01-01"),
        part(902, "Second", "2004-01-01"),
        %{"id" => "not-a-number", "title" => "Broken"}
      ])

      assert {:ok, franchise} = Franchises.for_media_item(Scope.unrestricted(), movie, config)
      assert franchise.total_count == 2
      assert Enum.map(franchise.entries, & &1.tmdb_id) == [901, 902]
    end
  end
end
