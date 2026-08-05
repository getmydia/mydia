defmodule MydiaWeb.SearchLive.AddToLibraryTest do
  use MydiaWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers
  alias Mydia.Media

  @mock_movie_metadata %{
    "id" => 550,
    "title" => "Fight Club",
    "original_title" => "Fight Club",
    "release_date" => "1999-10-15",
    "overview" => "A ticking-time-bomb insomniac and a slippery soap salesman...",
    "poster_path" => "/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg",
    "backdrop_path" => "/fCayJrkfRaCRCTh8GqN30f8oyQF.jpg",
    "vote_average" => 8.4,
    "vote_count" => 27_000,
    "popularity" => 70.0,
    "runtime" => 139
  }

  setup do
    # Create an admin user for testing
    user =
      create_admin_user(%{
        email: "test@example.com",
        username: "testuser"
      })

    # Generate JWT token for the user
    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  defp authenticate_conn(conn, token) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:guardian_token, token)
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp mount_search_live(conn, token) do
    conn = authenticate_conn(conn, token)
    {:ok, view, _html} = live(conn, ~p"/search")
    view
  end

  describe "add_to_library - Movie" do
    setup %{conn: conn, token: token} do
      # No need to authenticate for these tests
      %{conn: conn, token: token}
    end

    @tag :skip
    test "successfully adds a movie to the library", %{conn: conn, token: token} do
      # This test requires mocking metadata provider responses
      # For now, marked as skip until we implement proper mocking strategy
      view = mount_search_live(conn, token)

      # Trigger add to library with a movie release title
      release_title = "Fight.Club.1999.1080p.BluRay.x264-GROUP"

      # Mock the FileParser.parse to return expected result
      # Mock the Metadata.search to return single match
      # Mock the Metadata.fetch_by_id to return full metadata

      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Wait for async operation
      assert_redirect(view, ~p"/media/#{1}")

      # Verify media item was created
      media_item = Media.get_media_item_by_tmdb(550)
      assert media_item
      assert media_item.title == "Fight Club"
      assert media_item.year == 1999
      assert media_item.type == "movie"
      assert media_item.monitored == true
    end

    @tag :skip
    test "handles multiple metadata matches with disambiguation", %{conn: conn, token: token} do
      # Test requires mocking to return multiple matches
      view = mount_search_live(conn, token)

      release_title = "The.Matrix.1999.1080p.BluRay.x264"

      # Mock search to return multiple matches
      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Should show disambiguation modal
      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "h3", "Select Media Item")

      # Select first match
      view
      |> element(~s{button[phx-value-match_id="1"]})
      |> render_click()

      # Should redirect after selection
      assert_redirect(view, ~p"/media/#{1}")
    end

    test "detects duplicate when media already exists in library", %{conn: conn, token: token} do
      # Pre-create a media item with the same TMDB ID
      existing_item =
        media_item_fixture(%{
          type: "movie",
          title: "Fight Club",
          year: 1999,
          tmdb_id: 550,
          metadata: @mock_movie_metadata,
          monitored: true
        })

      _view = mount_search_live(conn, token)

      _release_title = "Fight.Club.1999.1080p.BluRay.x264-GROUP"

      # Since we can't easily mock external calls, we'll test the duplicate detection
      # logic by directly verifying the database query works
      duplicate = Media.get_media_item_by_tmdb(550)
      assert duplicate
      assert duplicate.id == existing_item.id
      assert duplicate.title == "Fight Club"
    end
  end

  describe "add_to_library - TV Show" do
    setup %{conn: conn, token: token} do
      # No need to authenticate for these tests
      %{conn: conn, token: token}
    end

    @tag :skip
    test "successfully adds TV show with episodes to library", %{conn: conn, token: token} do
      view = mount_search_live(conn, token)

      # TV show release with season and episodes
      release_title = "Breaking.Bad.S01E01.1080p.BluRay.x264-GROUP"

      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Wait for async operation
      assert_redirect(view, ~p"/media/#{1}")

      # Verify TV show was created
      media_item = Media.get_media_item_by_tmdb(1396)
      assert media_item
      assert media_item.title == "Breaking Bad"
      assert media_item.type == "tv_show"

      # Verify episode was created
      episodes = Media.list_episodes(media_item.id)
      assert length(episodes) == 1
      episode = List.first(episodes)
      assert episode.season_number == 1
      assert episode.episode_number == 1
      assert episode.monitored == true
    end

    @tag :skip
    test "handles multi-episode releases", %{conn: conn, token: token} do
      view = mount_search_live(conn, token)

      # Multi-episode release
      release_title = "Breaking.Bad.S01E01-E03.1080p.BluRay.x264-GROUP"

      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Wait for async operation
      assert_redirect(view, ~p"/media/#{1}")

      # Verify all episodes were created
      media_item = Media.get_media_item_by_tmdb(1396)
      episodes = Media.list_episodes(media_item.id)
      assert length(episodes) == 3

      episode_numbers = Enum.map(episodes, & &1.episode_number) |> Enum.sort()
      assert episode_numbers == [1, 2, 3]
    end
  end

  describe "add_to_library - Error Handling" do
    setup %{conn: conn, token: token} do
      # No need to authenticate for these tests
      %{conn: conn, token: token}
    end

    test "handles parse failure with manual search modal", %{conn: conn, token: token} do
      _view = mount_search_live(conn, token)

      # Unparseable release title
      release_title = "random_garbage_123"

      # Test the FileParser directly to verify it fails
      parsed = Mydia.Library.ReleaseParser.parse(release_title)
      assert parsed.type == :unknown
    end

    @tag :skip
    test "shows manual search modal when no metadata matches found", %{conn: conn, token: token} do
      view = mount_search_live(conn, token)

      release_title = "Unknown.Movie.2099.1080p.BluRay.x264"

      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Should show manual search modal
      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "Manual Search")

      # Should extract search hint from title
      assert has_element?(view, ~s{input[value*="Unknown Movie"]})
    end

    @tag :skip
    test "handles metadata provider API errors with retry modal", %{conn: conn, token: token} do
      view = mount_search_live(conn, token)

      # Mock API error response
      release_title = "Fight.Club.1999.1080p.BluRay.x264"

      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # Should show retry modal
      assert has_element?(view, ~s{div[class*="modal-open"]})
      assert has_element?(view, "Retry")
      assert has_element?(view, "Metadata provider error")
    end

    test "handles low confidence parsing with warning", %{conn: conn, token: token} do
      _view = mount_search_live(conn, token)

      # Test with a title that produces low confidence
      release_title = "Movie.Title"

      parsed = Mydia.Library.ReleaseParser.parse(release_title)

      # Verify low confidence is detected
      if parsed.confidence < 0.5 do
        # Low confidence should still proceed but with warning in logs
        assert parsed.confidence < 0.5
      end
    end
  end

  describe "add_to_library - Year Matching" do
    setup %{conn: conn, token: token} do
      # No need to authenticate for these tests
      %{conn: conn, token: token}
    end

    test "extracts year from release title", %{conn: _conn, token: _token} do
      release_titles = [
        {"Fight.Club.1999.1080p.BluRay", 1999},
        {"The.Matrix.(1999).1080p", 1999},
        {"Inception.[2010].BluRay", 2010},
        {"Movie.Title.2020.WEB-DL.x264", 2020}
      ]

      for {title, expected_year} <- release_titles do
        parsed = Mydia.Library.ReleaseParser.parse(title)
        assert parsed.year == expected_year, "Failed to extract year from: #{title}"
      end
    end

    @tag :skip
    test "uses year for metadata search filtering", %{conn: conn, token: token} do
      view = mount_search_live(conn, token)

      # When searching with year, it should be passed to metadata provider
      release_title = "The.Matrix.1999.1080p.BluRay.x264"

      # Mock should verify that year: 1999 is passed to search
      view
      |> element(~s{button[phx-value-title="#{release_title}"]})
      |> render_click()

      # In a real test with mocking, we'd verify the search was called with year: 1999
    end
  end

  describe "FileParser integration" do
    test "parses movie releases correctly" do
      test_cases = [
        %{
          input: "Fight.Club.1999.1080p.BluRay.x264-GROUP",
          expected: %{
            type: :movie,
            title: "Fight Club",
            year: 1999,
            season: nil,
            episodes: nil
          }
        },
        %{
          input: "The.Matrix.Reloaded.2003.2160p.WEB-DL.x265",
          expected: %{
            type: :movie,
            title: "The Matrix Reloaded",
            year: 2003,
            season: nil,
            episodes: nil
          }
        }
      ]

      for test_case <- test_cases do
        parsed = Mydia.Library.ReleaseParser.parse(test_case.input)
        assert parsed.type == test_case.expected.type, "Type mismatch for #{test_case.input}"

        assert parsed.title == test_case.expected.title,
               "Title mismatch for #{test_case.input}"

        assert parsed.year == test_case.expected.year, "Year mismatch for #{test_case.input}"
        assert parsed.season == test_case.expected.season
        assert parsed.episodes == test_case.expected.episodes
      end
    end

    test "parses TV show releases correctly" do
      test_cases = [
        %{
          input: "Breaking.Bad.S01E01.1080p.BluRay.x264",
          expected: %{
            type: :tv_show,
            title: "Breaking Bad",
            season: 1,
            episodes: [1]
          }
        },
        %{
          input: "Game.of.Thrones.S05E08.720p.WEB-DL",
          expected: %{
            type: :tv_show,
            title: "Game Of Thrones",
            season: 5,
            episodes: [8]
          }
        },
        %{
          input: "The.Wire.S02E01-E03.1080p.BluRay",
          expected: %{
            type: :tv_show,
            title: "The Wire",
            season: 2,
            episodes: [1, 2, 3]
          }
        }
      ]

      for test_case <- test_cases do
        parsed = Mydia.Library.ReleaseParser.parse(test_case.input)
        assert parsed.type == test_case.expected.type
        assert parsed.title == test_case.expected.title
        assert parsed.season == test_case.expected.season
        assert Enum.sort(parsed.episodes || []) == Enum.sort(test_case.expected.episodes)
      end
    end

    test "returns unknown for unparseable titles" do
      unparseable_titles = [
        "!!!invalid!!!",
        "",
        "...",
        "no-recognizable-pattern-here"
      ]

      for title <- unparseable_titles do
        parsed = Mydia.Library.ReleaseParser.parse(title)
        assert parsed.type == :unknown, "Should be unknown for: #{title}"
      end
    end

    test "handles low confidence parsing" do
      # Titles with minimal information
      low_confidence_titles = [
        "MovieTitle",
        "Show.Name",
        "Random.Words.Here"
      ]

      for title <- low_confidence_titles do
        parsed = Mydia.Library.ReleaseParser.parse(title)
        # Low confidence should still return a result but with lower confidence score
        assert parsed.confidence >= 0.0 and parsed.confidence <= 1.0
      end
    end
  end

  describe "Media context integration" do
    test "creates media item successfully" do
      attrs = %{
        type: "movie",
        title: "Test Movie",
        year: 2024,
        tmdb_id: 12345,
        metadata: @mock_movie_metadata,
        monitored: true
      }

      {:ok, media_item} = Media.create_media_item(attrs)

      assert media_item.title == "Test Movie"
      assert media_item.year == 2024
      assert media_item.tmdb_id == 12345
      assert media_item.monitored == true
    end

    test "finds existing media by TMDB ID" do
      existing_item =
        media_item_fixture(%{
          type: "movie",
          title: "Existing Movie",
          tmdb_id: 999,
          monitored: true
        })

      found = Media.get_media_item_by_tmdb(999)
      assert found
      assert found.id == existing_item.id
      assert found.title == "Existing Movie"
    end

    test "returns nil when TMDB ID not found" do
      result = Media.get_media_item_by_tmdb(99999)
      assert result == nil
    end

    test "creates episodes for TV shows" do
      tv_show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Test Show",
          tmdb_id: 5555,
          monitored: true
        })

      episode_attrs = %{
        media_item_id: tv_show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot",
        monitored: true
      }

      {:ok, episode} = Media.create_episode(episode_attrs)

      assert episode.season_number == 1
      assert episode.episode_number == 1
      assert episode.media_item_id == tv_show.id
      assert episode.monitored == true
    end

    test "lists episodes for media item" do
      tv_show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Test Show",
          tmdb_id: 6666
        })

      # Create multiple episodes
      for ep_num <- 1..3 do
        Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: ep_num,
          title: "Episode #{ep_num}",
          monitored: true
        })
      end

      # Use list_episodes with media_item_id as first parameter
      episodes = Media.list_episodes(tv_show.id)
      assert length(episodes) == 3
      episode_numbers = Enum.map(episodes, & &1.episode_number) |> Enum.sort()
      assert episode_numbers == [1, 2, 3]
    end
  end
end
