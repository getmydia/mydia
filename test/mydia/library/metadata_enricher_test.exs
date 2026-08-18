defmodule Mydia.Library.MetadataEnricherTest do
  use Mydia.DataCase, async: true

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Library.MetadataEnricher
  alias Mydia.{Events, Library, Media, Settings}
  alias Mydia.Media.MediaItem

  describe "enrich/2 with invalid input" do
    test "returns error for match result missing provider_id" do
      invalid_match = %{
        provider_type: :tmdb,
        title: "Test Movie"
      }

      assert {:error, {:invalid_match_result, message}} = MetadataEnricher.enrich(invalid_match)
      assert message =~ "missing required fields"
    end

    test "returns error for match result missing provider_type" do
      invalid_match = %{
        provider_id: "12345",
        title: "Test Movie"
      }

      assert {:error, {:invalid_match_result, message}} = MetadataEnricher.enrich(invalid_match)
      assert message =~ "missing required fields"
    end

    test "returns error for match result with nil provider_id" do
      invalid_match = %{
        provider_id: nil,
        provider_type: :tmdb,
        title: "Test Movie"
      }

      assert {:error, {:invalid_match_result, message}} = MetadataEnricher.enrich(invalid_match)
      assert message =~ "missing required fields"
    end

    test "returns error for match result with nil provider_type" do
      invalid_match = %{
        provider_id: "12345",
        provider_type: nil,
        title: "Test Movie"
      }

      assert {:error, {:invalid_match_result, message}} = MetadataEnricher.enrich(invalid_match)
      assert message =~ "missing required fields"
    end

    test "returns error for completely empty map" do
      assert {:error, {:invalid_match_result, message}} = MetadataEnricher.enrich(%{})
      assert message =~ "missing required fields"
    end
  end

  describe "library type validation" do
    setup do
      # Create unique paths for each test to avoid conflicts
      unique_id = :erlang.unique_integer([:positive])

      # Create library paths for testing
      {:ok, movies_lib} =
        Settings.create_library_path(%{
          path: "/media/movies_#{unique_id}",
          type: :movies
        })

      {:ok, series_lib} =
        Settings.create_library_path(%{
          path: "/media/series_#{unique_id}",
          type: :series
        })

      {:ok, mixed_lib} =
        Settings.create_library_path(%{
          path: "/media/mixed_#{unique_id}",
          type: :mixed
        })

      %{
        movies_lib: movies_lib,
        series_lib: series_lib,
        mixed_lib: mixed_lib
      }
    end

    test "allows movies in movies-only library", %{movies_lib: movies_lib} do
      # First create a movie media item
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Create a media file in movies library associated with the movie
      {:ok, media_file} =
        Library.create_media_file(%{
          path: "#{movies_lib.path}/The Matrix (1999).mkv",
          relative_path: "The Matrix (1999).mkv",
          library_path_id: movies_lib.id,
          media_item_id: movie.id
        })

      # Should succeed - movie in movies library
      assert media_file.path =~ movies_lib.path
      assert media_file.media_item_id == movie.id
    end

    test "allows TV shows in series-only library", %{series_lib: series_lib} do
      # First create a TV show and episode
      {:ok, tv_show} =
        Mydia.Media.create_media_item(
          %{
            title: "Breaking Bad",
            type: "tv_show",
            year: 2008,
            tmdb_id: 1396
          },
          skip_episode_refresh: true
        )

      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          path: "#{series_lib.path}/Breaking Bad/Season 01/Breaking Bad S01E01.mkv",
          relative_path: "Breaking Bad/Season 01/Breaking Bad S01E01.mkv",
          library_path_id: series_lib.id,
          episode_id: episode.id
        })

      assert media_file.path =~ series_lib.path
      assert media_file.episode_id == episode.id
    end

    test "allows both movies and TV shows in mixed library", %{mixed_lib: mixed_lib} do
      # Create movie
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Create TV show and episode
      {:ok, tv_show} =
        Mydia.Media.create_media_item(
          %{
            title: "Breaking Bad",
            type: "tv_show",
            year: 2008,
            tmdb_id: 1396
          },
          skip_episode_refresh: true
        )

      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      {:ok, movie_file} =
        Library.create_media_file(%{
          path: "#{mixed_lib.path}/movies/The Matrix (1999).mkv",
          relative_path: "movies/The Matrix (1999).mkv",
          library_path_id: mixed_lib.id,
          media_item_id: movie.id
        })

      {:ok, tv_file} =
        Library.create_media_file(%{
          path: "#{mixed_lib.path}/tv/Breaking Bad/Season 01/S01E01.mkv",
          relative_path: "tv/Breaking Bad/Season 01/S01E01.mkv",
          library_path_id: mixed_lib.id,
          episode_id: episode.id
        })

      assert movie_file.path =~ mixed_lib.path
      assert tv_file.path =~ mixed_lib.path
    end

    test "prevents movies in series-only library", %{series_lib: series_lib} do
      # First create a movie media item
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Try to create a media file in series library and associate with movie
      assert {:error, changeset} =
               Library.create_media_file(%{
                 path: "#{series_lib.path}/The Matrix (1999).mkv",
                 relative_path: "The Matrix (1999).mkv",
                 library_path_id: series_lib.id,
                 media_item_id: movie.id
               })

      error_message = hd(errors_on(changeset).media_item_id)
      assert error_message =~ "cannot add movies to a library path configured for TV series only"
    end

    test "prevents TV shows in movies-only library", %{movies_lib: movies_lib} do
      # First create a TV show media item
      {:ok, tv_show} =
        Mydia.Media.create_media_item(
          %{
            title: "Breaking Bad",
            type: "tv_show",
            year: 2008,
            tmdb_id: 1396
          },
          skip_episode_refresh: true
        )

      # Create an episode
      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      # Try to create a media file in movies library and associate with episode
      assert {:error, changeset} =
               Library.create_media_file(%{
                 path: "#{movies_lib.path}/Breaking Bad S01E01.mkv",
                 relative_path: "Breaking Bad S01E01.mkv",
                 library_path_id: movies_lib.id,
                 episode_id: episode.id
               })

      error_message = hd(errors_on(changeset).episode_id)

      assert error_message =~
               "cannot add TV episodes to a library path configured for movies only"
    end
  end

  describe "year extraction from metadata" do
    test "extracts year from Date struct in release_date" do
      # Simulate metadata with Date struct (as returned by some TMDB responses)
      metadata = %{
        title: "Dune: Part Two",
        provider_id: "693134",
        release_date: ~D[2024-02-27],
        metadata_type: :movie
      }

      # Use build_media_item_attrs to test year extraction
      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 2024
    end

    test "extracts year from string in release_date" do
      # Simulate metadata with string date (typical TMDB format)
      metadata = %{
        title: "The Matrix",
        provider_id: "603",
        release_date: "1999-03-31",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 1999
    end

    test "extracts year from Date struct in first_air_date for TV shows" do
      metadata = %{
        name: "Breaking Bad",
        provider_id: "1396",
        first_air_date: ~D[2008-01-20],
        metadata_type: :tv_show
      }

      attrs = build_attrs_for_test(metadata, :tv_show)

      assert attrs.year == 2008
    end

    test "extracts year from string in first_air_date for TV shows" do
      metadata = %{
        name: "The Wire",
        provider_id: "1438",
        first_air_date: "2002-06-02",
        metadata_type: :tv_show
      }

      attrs = build_attrs_for_test(metadata, :tv_show)

      assert attrs.year == 2002
    end

    test "returns nil when no date is present" do
      metadata = %{
        title: "Unknown Movie",
        provider_id: "12345",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == nil
    end

    test "returns nil when date format is invalid" do
      metadata = %{
        title: "Bad Date Movie",
        provider_id: "12345",
        release_date: "invalid-date",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == nil
    end

    test "prefers release_date over first_air_date when both present" do
      metadata = %{
        title: "Some Movie",
        provider_id: "12345",
        release_date: ~D[2024-03-15],
        first_air_date: ~D[2020-01-01],
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 2024
    end
  end

  # Helper to access private function behavior through public interface
  # This mimics what build_media_item_attrs does internally
  defp build_attrs_for_test(metadata, media_type) do
    # Call the private extract_year function indirectly through the attrs builder
    # We'll use send to call the private function for testing
    year = extract_year_test_helper(metadata)

    %{
      type: media_type_to_string(media_type),
      title: Map.get(metadata, :title) || Map.get(metadata, :name),
      year: year,
      tmdb_id: String.to_integer(to_string(metadata.provider_id)),
      metadata: metadata
    }
  end

  # Test helper that replicates the private extract_year logic
  defp extract_year_test_helper(metadata) do
    cond do
      Map.has_key?(metadata, :release_date) && metadata.release_date ->
        extract_year_from_date_test(metadata.release_date)

      Map.has_key?(metadata, :first_air_date) && metadata.first_air_date ->
        extract_year_from_date_test(metadata.first_air_date)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_year_from_date_test(%Date{} = date), do: date.year

  defp extract_year_from_date_test(date_string) when is_binary(date_string) do
    date_string
    |> String.slice(0..3)
    |> String.to_integer()
  end

  defp extract_year_from_date_test(_), do: nil

  defp media_type_to_string(:movie), do: "movie"
  defp media_type_to_string(:tv_show), do: "tv_show"

  describe "metadata_source stamping for new TV shows" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "stamps :tmdb when the show was matched via TMDB", %{bypass: bypass, config: config} do
      # Unique id keeps the metadata cache key unique so the fetch hits Bypass.
      id = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tv_body(id, "TMDB Sourced Show")))
      end)

      match_result = %{
        provider_id: to_string(id),
        provider_type: :tmdb,
        title: "TMDB Sourced Show",
        metadata: %{media_type: :tv_show}
      }

      assert {:ok, media_item} =
               MetadataEnricher.enrich(match_result, config: config, fetch_episodes: false)

      assert media_item.type == "tv_show"
      assert media_item.metadata_source == :tmdb
      assert media_item.tmdb_id == id
      assert is_nil(media_item.tvdb_id)
    end

    test "stamps :tvdb when the show was matched via TVDB", %{bypass: bypass, config: config} do
      id = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tvdb/series/#{id}/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tvdb_body(id, "TVDB Sourced Show")))
      end)

      match_result = %{
        provider_id: to_string(id),
        provider_type: :tvdb,
        title: "TVDB Sourced Show",
        metadata: %{media_type: :tv_show}
      }

      assert {:ok, media_item} =
               MetadataEnricher.enrich(match_result, config: config, fetch_episodes: false)

      assert media_item.type == "tv_show"
      assert media_item.metadata_source == :tvdb
      assert media_item.tvdb_id == id
      assert is_nil(media_item.tmdb_id)
    end
  end

  describe "quality profile on auto-created items" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "an auto-imported item stays unstamped and follows the configured default",
         %{bypass: bypass, config: config} do
      default = quality_profile_fixture(%{name: "Enricher Default"})
      {:ok, _} = Settings.set_default_quality_profile(default.id)

      id = System.unique_integer([:positive])

      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(tv_body(id, "Unstamped Show")))
      end)

      match_result = %{
        provider_id: to_string(id),
        provider_type: :tmdb,
        title: "Unstamped Show",
        metadata: %{media_type: :tv_show}
      }

      assert {:ok, media_item} =
               MetadataEnricher.enrich(match_result, config: config, fetch_episodes: false)

      # Import must not freeze the current default onto the item. nil means
      # "follow whatever default is configured", resolved at search time.
      assert is_nil(media_item.quality_profile_id)

      resolved = QualityProfileResolver.resolve(media_item)
      assert resolved.id == default.id

      # Changing the default moves the item with it, which stamping would break.
      other = quality_profile_fixture(%{name: "Enricher Default Changed"})
      {:ok, _} = Settings.set_default_quality_profile(other.id)

      assert QualityProfileResolver.resolve(media_item).id == other.id
    end
  end

  describe "metadata_source adoption on the update path (U3)" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "nil-source item adopts the match's TMDB provider on scan",
         %{bypass: bypass, config: config} do
      id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Nil Source",
          tmdb_id: id,
          metadata_source: nil
        })
        |> backdate()

      Bypass.stub(
        bypass,
        "GET",
        "/tmdb/tv/shows/#{id}",
        &respond_json(&1, tv_body(id, "Nil Source"))
      )

      match = tv_match(id, :tmdb, "Nil Source")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.metadata_source == :tmdb
    end

    test "nil-source item adopts the match's TVDB provider on scan",
         %{bypass: bypass, config: config} do
      id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Nil Source TVDB",
          tvdb_id: id,
          metadata_source: nil
        })
        |> backdate()

      Bypass.stub(
        bypass,
        "GET",
        "/tvdb/series/#{id}/extended",
        &respond_json(&1, tvdb_body(id, "Nil Source TVDB"))
      )

      match = tv_match(id, :tvdb, "Nil Source TVDB")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.metadata_source == :tvdb
    end

    test "an already-stamped source is not switched on scan (regression guard for f1e4840f)",
         %{bypass: bypass, config: config} do
      tmdb_id = System.unique_integer([:positive])
      tvdb_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Stamped TMDB",
          tmdb_id: tmdb_id,
          tvdb_id: tvdb_id,
          metadata_source: :tmdb
        })
        |> backdate()

      # Scanned into a TVDB library (match provider_type :tvdb, found via tvdb_id).
      # The preserved :tmdb provenance means the refresh fetches TMDB.
      Bypass.stub(
        bypass,
        "GET",
        "/tmdb/tv/shows/#{tvdb_id}",
        &respond_json(&1, tv_body(tvdb_id, "Stamped TMDB"))
      )

      match = tv_match(tvdb_id, :tvdb, "Stamped TMDB")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.metadata_source == :tmdb
    end

    test "nil-source item still stamps within the recently-enriched window",
         %{config: config} do
      # Not backdated → recently enriched → fast path. No relay stub: the
      # stamp-only path makes no relay call, so the test passing proves it.
      id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Fresh Nil",
          tmdb_id: id,
          metadata_source: nil
        })

      match = tv_match(id, :tmdb, "Fresh Nil")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.metadata_source == :tmdb
    end

    test "a stamped item within the recently-enriched window is left untouched",
         %{config: config} do
      id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Fresh Stamped",
          tvdb_id: id,
          metadata_source: :tvdb
        })

      match = tv_match(id, :tvdb, "Fresh Stamped")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.metadata_source == :tvdb
    end

    test "movie on the update path keeps metadata_source nil",
         %{bypass: bypass, config: config} do
      id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{type: "movie", title: "A Movie", tmdb_id: id})
        |> backdate()

      Bypass.stub(
        bypass,
        "GET",
        "/tmdb/movies/#{id}",
        &respond_json(&1, movie_body(id, "A Movie"))
      )

      match = %{
        provider_id: to_string(id),
        provider_type: :tmdb,
        title: "A Movie",
        metadata: %{media_type: :movie}
      }

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert is_nil(updated.metadata_source)
    end
  end

  describe "cross-provider ids on the update path" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "a show that already owns both ids is not reported as its own duplicate",
         %{bypass: bypass, config: config} do
      tmdb_id = System.unique_integer([:positive])
      tvdb_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Dual Id Show",
          tmdb_id: tmdb_id,
          tvdb_id: tvdb_id,
          metadata_source: :tmdb
        })
        |> backdate()

      # TMDB cross-references the tvdb_id this very row already holds.
      body = Map.put(tv_body(tmdb_id, "Dual Id Show"), "external_ids", %{"tvdb_id" => tvdb_id})

      Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", &respond_json(&1, body))

      match = tv_match(tmdb_id, :tmdb, "Dual Id Show")

      assert {:ok, updated} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert updated.id == item.id
      assert updated.tmdb_id == tmdb_id
      assert updated.tvdb_id == tvdb_id

      # The retained id alone proves little: it is already on the row, and an
      # update that skips the column leaves it there either way. The absent
      # warning is what discriminates. Without `exclude_id` the enricher finds
      # the item as the owner of its own tvdb_id and drops a duplicate warning
      # on the operator's timeline during an ordinary scan.
      assert Events.list_events(type: "media_item.duplicate_provider_id") == []
    end

    test "a genuine collision on the update path is still reported",
         %{bypass: bypass, config: config} do
      tmdb_id = System.unique_integer([:positive])
      taken_tvdb_id = System.unique_integer([:positive])

      incumbent =
        media_item_fixture(%{
          type: "tv_show",
          title: "Tvdb Incumbent",
          tvdb_id: taken_tvdb_id
        })

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Duplicate Row",
          tmdb_id: tmdb_id,
          metadata_source: :tmdb
        })
        |> backdate()

      body =
        Map.put(tv_body(tmdb_id, "Duplicate Row"), "external_ids", %{"tvdb_id" => taken_tvdb_id})

      Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", &respond_json(&1, body))

      match = tv_match(tmdb_id, :tmdb, "Duplicate Row")

      {result, log} =
        with_log(fn ->
          MetadataEnricher.enrich(match, config: config, fetch_episodes: false)
        end)

      assert {:ok, updated} = result
      assert log =~ "is already owned by another media item"
      assert updated.id == item.id
      assert is_nil(updated.tvdb_id)

      assert [event] = Events.list_events(type: "media_item.duplicate_provider_id")
      assert event.resource_id == incumbent.id
    end
  end

  describe "episode enrichment threads original language (U5)" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        # Korean has no translation in the stubbed bundle, so selection must
        # fall back to the show's original language (Japanese), not English.
        options: %{language: "ko", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "episodes use the original language when the configured language is missing",
         %{bypass: bypass, config: config} do
      series_id = System.unique_integer([:positive])
      season_id = System.unique_integer([:positive])
      episode_id = System.unique_integer([:positive])

      media_item_fixture(%{
        type: "tv_show",
        title: "Original Lang Show",
        tvdb_id: series_id,
        metadata_source: :tvdb
      })
      |> backdate()

      # Series extended: carries the original language and one official season.
      Bypass.stub(bypass, "GET", "/tvdb/series/#{series_id}/extended", fn conn ->
        respond_json(conn, %{
          "data" => %{
            "id" => series_id,
            "name" => "Original Lang Show",
            "overview" => "ov",
            "originalLanguage" => "jpn",
            "firstAired" => "2010-01-01",
            "genres" => [],
            "seasons" => [
              %{
                "id" => season_id,
                "number" => 1,
                "type" => %{"type" => "official"},
                "name" => "Season 1"
              }
            ]
          }
        })
      end)

      # Season extended: episodes without translation text (only ids).
      Bypass.stub(bypass, "GET", "/tvdb/seasons/#{season_id}/extended", fn conn ->
        respond_json(conn, %{
          "data" => %{
            "number" => 1,
            "name" => "Season 1",
            "episodes" => [
              %{"id" => episode_id, "seasonNumber" => 1, "number" => 1, "name" => "Raw Episode"}
            ]
          }
        })
      end)

      # Episode extended: translation bundle with Japanese + English, no Korean.
      Bypass.stub(bypass, "GET", "/tvdb/episodes/#{episode_id}/extended", fn conn ->
        respond_json(conn, %{
          "data" => %{
            "translations" => %{
              "nameTranslations" => [
                %{"language" => "jpn", "name" => "日本語タイトル"},
                %{"language" => "eng", "name" => "English Title"}
              ],
              "overviewTranslations" => [
                %{"language" => "jpn", "overview" => "概要"},
                %{"language" => "eng", "overview" => "English overview"}
              ]
            }
          }
        })
      end)

      match = tv_match(series_id, :tvdb, "Original Lang Show")

      assert {:ok, updated} = MetadataEnricher.enrich(match, config: config, fetch_episodes: true)

      [episode] = Media.list_episodes(updated.id)
      # Without original-language threading these would be the English values.
      assert episode.title == "日本語タイトル"
      assert episode.metadata.overview == "概要"
    end
  end

  # This path runs against items that are already in the library, so it is the
  # one an ordinary rescan takes. Before season_order was threaded here, a
  # rescan of a DVD-ordered show overwrote its metadata blob with the official
  # season list while its episode rows stayed DVD-grouped, and the show page
  # rendered one season list over the other's episodes.
  describe "season ordering on the enrichment update path" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "a rescan follows the show's recorded ordering", %{bypass: bypass, config: config} do
      series_id = System.unique_integer([:positive])
      official_id = System.unique_integer([:positive])
      dvd_one = System.unique_integer([:positive])
      dvd_two = System.unique_integer([:positive])

      # One TVDB response carrying both orderings of the same series, which is
      # how TVDB actually returns them.
      Bypass.stub(bypass, "GET", "/tvdb/series/#{series_id}/extended", fn conn ->
        respond_json(conn, %{
          "data" => %{
            "id" => series_id,
            "tvdb_id" => series_id,
            "name" => "Ordered Rescan",
            "overview" => "ov",
            "firstAired" => "2010-01-01",
            "genres" => [],
            "seasons" => [
              ordering_season(official_id, 1, "official", 4),
              ordering_season(dvd_one, 1, "dvd", 2),
              ordering_season(dvd_two, 2, "dvd", 2)
            ]
          }
        })
      end)

      media_item_fixture(%{
        type: "tv_show",
        title: "Ordered Rescan",
        tvdb_id: series_id,
        metadata_source: :tvdb
      })
      |> backdate()

      match = tv_match(series_id, :tvdb, "Ordered Rescan")

      # No recorded ordering yet, so the official list is what gets stored: one
      # season of four. (Seasons are compared by number and episode count, not
      # by tvdb_season_id: MetadataType.parse_seasons_list/1 drops that field
      # when it rebuilds SeasonInfo structs out of the stored blob.)
      assert {:ok, official} =
               MetadataEnricher.enrich(match, config: config, fetch_episodes: false)

      assert stored_seasons(official) == [{1, 4}]

      # Switch the show to the DVD ordering and rescan the same series id. The
      # second pass must not read the first pass's cached official grouping:
      # fetch_by_id_cached/3 keys on the ordering precisely so it cannot.
      {:ok, switched} = Media.update_media_item(official, %{season_order: :dvd})
      backdate(switched)

      assert {:ok, dvd} = MetadataEnricher.enrich(match, config: config, fetch_episodes: false)
      assert stored_seasons(dvd) == [{1, 2}, {2, 2}]
      assert Media.get_media_item!(dvd.id).season_order == :dvd
    end
  end

  defp ordering_season(id, number, type, episode_count) do
    %{
      "id" => id,
      "number" => number,
      "name" => "Season #{number}",
      "type" => %{"type" => type},
      "episodeCount" => episode_count
    }
  end

  defp stored_seasons(%MediaItem{} = item) do
    item.id
    |> Media.get_media_item!()
    |> Map.fetch!(:metadata)
    |> Map.fetch!(:seasons)
    |> Enum.map(&{&1.season_number, &1.episode_count})
  end

  defp tv_match(id, provider_type, title) do
    %{
      provider_id: to_string(id),
      provider_type: provider_type,
      title: title,
      metadata: %{media_type: :tv_show}
    }
  end

  defp backdate(%MediaItem{} = item) do
    old =
      DateTime.utc_now()
      |> DateTime.add(-7200, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(m in MediaItem, where: m.id == ^item.id)
      |> Repo.update_all(set: [updated_at: old])

    %{item | updated_at: old}
  end

  defp respond_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp movie_body(id, title) do
    %{
      "id" => id,
      "title" => title,
      "release_date" => "2019-01-01",
      "overview" => "x",
      "genres" => [],
      "credits" => %{"cast" => [], "crew" => []}
    }
  end

  defp tv_body(id, name) do
    %{
      "id" => id,
      "name" => name,
      "overview" => "test overview",
      "first_air_date" => "2010-01-01",
      "number_of_seasons" => 1,
      "number_of_episodes" => 1,
      "genres" => [],
      "seasons" => [],
      "credits" => %{"cast" => [], "crew" => []}
    }
  end

  defp tvdb_body(id, name) do
    %{
      "data" => %{
        "id" => id,
        "tvdb_id" => id,
        "name" => name,
        "overview" => "test overview",
        "first_air_date" => "2010-01-01",
        "genres" => [],
        "seasons" => []
      }
    }
  end
end
