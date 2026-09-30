defmodule Mydia.Metadata.RegionalSourcesTest do
  use Mydia.DataCase, async: false

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.RegionalSources
  alias Mydia.Metadata.Structs.WatchProvider

  @today ~D[2026-09-29]
  @maple {:service, 8001, "Maplestream"}
  @services [%{"id" => 8001, "name" => "Maplestream"}, %{"id" => 8002, "name" => "Northflix"}]

  describe "sources_for/3" do
    test "movies: cinemas, then services in saved order" do
      assert RegionalSources.sources_for("CA", @services, :movie) == [
               :in_cinemas,
               :coming_soon,
               {:service, 8001, "Maplestream"},
               {:service, 8002, "Northflix"}
             ]
    end

    test "tv drops the cinema sources" do
      assert RegionalSources.sources_for("CA", @services, :tv_show) == [
               {:service, 8001, "Maplestream"},
               {:service, 8002, "Northflix"}
             ]
    end

    test "no services and tv: nothing" do
      assert RegionalSources.sources_for("CA", [], :tv_show) == []
    end

    test "no country, no sources" do
      assert RegionalSources.sources_for(nil, @services, :movie) == []
    end
  end

  describe "opts/4" do
    test "in cinemas: theatrical, regional, last six weeks" do
      assert RegionalSources.opts(:in_cinemas, :movie, "CA", @today) == [
               region: "CA",
               with_release_type: "2|3",
               release_date_gte: "2026-08-18",
               release_date_lte: "2026-09-29",
               sort_by: "popularity.desc"
             ]
    end

    test "coming soon: tomorrow to ninety days out, soonest first" do
      assert RegionalSources.opts(:coming_soon, :movie, "CA", @today) == [
               region: "CA",
               with_release_type: "2|3",
               release_date_gte: "2026-09-30",
               release_date_lte: "2026-12-28",
               sort_by: "primary_release_date.asc"
             ]
    end

    test "service: flatrate in the region, released, newest first, with a vote floor" do
      assert RegionalSources.opts(@maple, :movie, "CA", @today) == [
               watch_region: "CA",
               with_watch_providers: "8001",
               with_watch_monetization_types: "flatrate",
               release_date_lte: "2026-09-29",
               min_votes: 10,
               sort_by: "primary_release_date.desc"
             ]

      assert Keyword.get(RegionalSources.opts(@maple, :tv_show, "CA", @today), :sort_by) ==
               "first_air_date.desc"
    end
  end

  describe "labels and params" do
    test "labels" do
      assert RegionalSources.label(:in_cinemas, "CA") == "In cinemas"
      assert RegionalSources.label(:coming_soon, "CA") == "Coming soon"
      assert RegionalSources.label(@maple, "CA") == "Latest on Maplestream"
    end

    test "a stale made_here param resolves to nothing" do
      sources = RegionalSources.sources_for("CA", @services, :movie)
      assert RegionalSources.find(sources, "made_here") == nil
    end

    test "params round-trip only through the user's own sources" do
      sources = RegionalSources.sources_for("CA", @services, :movie)

      for source <- sources do
        assert RegionalSources.find(sources, RegionalSources.to_param(source)) == source
      end

      assert RegionalSources.to_param(@maple) == "service-8001"
      assert RegionalSources.find(sources, "service-9999") == nil
      assert RegionalSources.find(sources, "bogus") == nil
      assert RegionalSources.find(sources, nil) == nil
    end
  end

  describe "fetching" do
    setup do
      bypass = Bypass.open()
      previous = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")
      Cache.clear()

      on_exit(fn ->
        Cache.clear()

        case previous do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      %{bypass: bypass}
    end

    defp stub(bypass, path, results) do
      Bypass.stub(bypass, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"page" => 1, "total_pages" => 1, "results" => results})
        )
      end)
    end

    test "fetch_mixed interleaves movies and shows newest first", %{bypass: bypass} do
      stub(bypass, "/tmdb/movies/discover", [
        %{"id" => 1, "title" => "Quiet Lanterns", "release_date" => "2026-09-01"},
        %{"id" => 2, "title" => "Paper Harbour", "release_date" => "2026-06-01"}
      ])

      stub(bypass, "/tmdb/tv/discover", [
        %{"id" => 3, "name" => "The Tidewatch", "first_air_date" => "2026-07-15"}
      ])

      assert {:ok, results} = RegionalSources.fetch_mixed(@maple, "CA", [], @today)
      assert Enum.map(results, & &1.title) == ["Quiet Lanterns", "The Tidewatch", "Paper Harbour"]
    end

    test "fetch_mixed for a cinema source only asks for movies", %{bypass: bypass} do
      stub(bypass, "/tmdb/movies/discover", [%{"id" => 1, "title" => "Quiet Lanterns"}])

      assert {:ok, [%{title: "Quiet Lanterns"}]} =
               RegionalSources.fetch_mixed(:in_cinemas, "CA", [], @today)
    end

    test "available_services merges movie and tv lists by id", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/tmdb/watch/providers/movie", fn conn ->
        body = %{
          "results" => [
            %{"provider_id" => 1, "provider_name" => "Maplestream", "display_priority" => 2}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.stub(bypass, "GET", "/tmdb/watch/providers/tv", fn conn ->
        body = %{
          "results" => [
            %{"provider_id" => 1, "provider_name" => "Maplestream", "display_priority" => 2},
            %{"provider_id" => 2, "provider_name" => "Northflix", "display_priority" => 1}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, [%WatchProvider{name: "Northflix"}, %WatchProvider{name: "Maplestream"}]} =
               RegionalSources.available_services("CA")
    end
  end

  describe "writes" do
    setup do
      user = Mydia.AccountsFixtures.user_fixture()
      %{user: user}
    end

    defp prefs(user), do: Accounts.get_user_preference!(user)

    test "changing country keeps only services the new region offers", %{user: user} do
      {:ok, _} = RegionalSources.change_home_country(user, "CA", fn _ -> {:ok, []} end)
      {:ok, _} = RegionalSources.put_services(user, @services)

      available = fn "FR" -> {:ok, [%WatchProvider{id: 8002, name: "Northflix"}]} end
      {:ok, _} = RegionalSources.change_home_country(user, "FR", available)

      assert UserPreference.discover_home_country(prefs(user)) == "FR"

      assert UserPreference.discover_streaming_services(prefs(user)) == [
               %{"id" => 8002, "name" => "Northflix"}
             ]
    end

    test "a failed provider lookup clears the services but saves the country", %{user: user} do
      {:ok, _} = RegionalSources.change_home_country(user, "CA", fn _ -> {:ok, []} end)
      {:ok, _} = RegionalSources.put_services(user, @services)

      {:ok, _} = RegionalSources.change_home_country(user, "FR", fn _ -> {:error, :down} end)

      assert UserPreference.discover_home_country(prefs(user)) == "FR"
      assert UserPreference.discover_streaming_services(prefs(user)) == []
    end

    test "removing the country clears the services", %{user: user} do
      {:ok, _} = RegionalSources.change_home_country(user, "CA", fn _ -> {:ok, []} end)
      {:ok, _} = RegionalSources.put_services(user, @services)

      {:ok, _} = RegionalSources.change_home_country(user, nil)

      assert prefs(user).preferences["discover_streaming_services"] == []
    end

    test "a malformed stored value does not crash a country change", %{user: user} do
      {:ok, _} = RegionalSources.change_home_country(user, "CA", fn _ -> {:ok, []} end)

      # Written straight to the row, past the changeset, as a hand edit would be.
      prefs(user)
      |> Ecto.Changeset.change(
        preferences: Map.put(prefs(user).preferences, "discover_streaming_services", "junk")
      )
      |> Mydia.Repo.update!()

      available = fn "FR" -> {:ok, [%WatchProvider{id: 8002, name: "Northflix"}]} end
      assert {:ok, _} = RegionalSources.change_home_country(user, "FR", available)
      assert UserPreference.discover_streaming_services(prefs(user)) == []
    end

    test "put_country_settings saves country and services together", %{user: user} do
      assert {:ok, _} = RegionalSources.put_country_settings(user, "CA", @services)

      assert UserPreference.discover_home_country(prefs(user)) == "CA"
      assert UserPreference.discover_streaming_services(prefs(user)) == @services
    end

    test "put_country_settings with nil clears both", %{user: user} do
      {:ok, _} = RegionalSources.put_country_settings(user, "CA", @services)

      assert {:ok, _} = RegionalSources.put_country_settings(user, nil, @services)

      assert UserPreference.discover_home_country(prefs(user)) == nil
      assert prefs(user).preferences["discover_streaming_services"] == []
    end

    test "put_country_settings rejects an unlisted country and writes nothing", %{user: user} do
      {:ok, _} = RegionalSources.put_country_settings(user, "CA", @services)

      assert {:error, %Ecto.Changeset{}} =
               RegionalSources.put_country_settings(user, "XX", [])

      assert UserPreference.discover_home_country(prefs(user)) == "CA"
      assert UserPreference.discover_streaming_services(prefs(user)) == @services
    end

    test "put_country_settings overwrites a malformed stored value", %{user: user} do
      {:ok, _} = RegionalSources.put_country_settings(user, "CA", [])

      prefs(user)
      |> Ecto.Changeset.change(
        preferences: Map.put(prefs(user).preferences, "discover_streaming_services", "junk")
      )
      |> Mydia.Repo.update!()

      assert {:ok, _} = RegionalSources.put_country_settings(user, "FR", @services)
      assert UserPreference.discover_streaming_services(prefs(user)) == @services
    end
  end
end
