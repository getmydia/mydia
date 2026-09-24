defmodule Mydia.Downloads.TorrentMatcherAlternativeTitlesTest do
  use Mydia.DataCase, async: true

  import Mydia.Factory

  alias Mydia.Downloads.TorrentMatcher
  alias Mydia.Media
  alias Mydia.Metadata.Structs.MediaMetadata

  describe "alternative title matching" do
    setup do
      # Create a movie with alternative titles in metadata
      {:ok, movie_with_alt_titles} =
        Media.create_media_item(%{
          type: "movie",
          title: "Edge of Tomorrow",
          original_title: "Edge of Tomorrow",
          year: 2014,
          tmdb_id: 137_113,
          metadata: %{
            "alternative_titles" => [
              "Live Die Repeat",
              "Live Die Repeat: Edge of Tomorrow",
              "All You Need Is Kill"
            ]
          }
        })

      # Create another movie to test specificity
      {:ok, other_movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Tomorrow War",
          year: 2021,
          tmdb_id: 588_228,
          metadata: %{}
        })

      %{
        movie_with_alt_titles: movie_with_alt_titles,
        other_movie: other_movie
      }
    end

    test "matches movie using alternative title", %{movie_with_alt_titles: movie} do
      # Torrent using alternative title "Live Die Repeat"
      torrent_info = %{
        type: :movie,
        title: "Live Die Repeat",
        year: 2014
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.confidence >= 0.8
      assert match.match_reason =~ "Edge of Tomorrow"
    end

    test "matches movie using another alternative title", %{movie_with_alt_titles: movie} do
      # Torrent using alternative title "All You Need Is Kill"
      torrent_info = %{
        type: :movie,
        title: "All You Need Is Kill",
        year: 2014
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.confidence >= 0.8
    end

    test "primary title match scores higher than alternative title match", %{
      movie_with_alt_titles: movie
    } do
      # Match using primary title
      primary_torrent = %{
        type: :movie,
        title: "Edge of Tomorrow",
        year: 2014
      }

      {:ok, primary_match} = TorrentMatcher.find_match(primary_torrent)

      # Match using alternative title
      alt_torrent = %{
        type: :movie,
        title: "Live Die Repeat",
        year: 2014
      }

      {:ok, alt_match} = TorrentMatcher.find_match(alt_torrent)

      # Primary title match should have higher confidence due to -0.05 penalty for alt titles
      assert primary_match.confidence > alt_match.confidence
      assert primary_match.media_item.id == movie.id
      assert alt_match.media_item.id == movie.id
    end

    test "handles movie with no alternative titles gracefully" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          tmdb_id: 603,
          metadata: %{}
        })

      torrent_info = %{
        type: :movie,
        title: "The Matrix",
        year: 1999
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.confidence >= 0.8
    end

    test "handles movie with nil metadata gracefully" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Inception",
          year: 2010,
          tmdb_id: 27_205
        })

      torrent_info = %{
        type: :movie,
        title: "Inception",
        year: 2010
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.confidence >= 0.8
    end

    test "alternative title with different year still requires year validation" do
      {:ok, _movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Leon: The Professional",
          year: 1994,
          tmdb_id: 101,
          metadata: %{
            "alternative_titles" => ["Leon", "The Professional"]
          }
        })

      # Torrent with matching alternative title but wrong year
      torrent_info = %{
        type: :movie,
        title: "Leon",
        year: 2010
      }

      # Should still fail or have very low confidence due to year mismatch
      result = TorrentMatcher.find_match(torrent_info)

      case result do
        {:ok, match} ->
          # If it matches, confidence should be very low due to year penalty
          assert match.confidence < 0.5

        {:error, :no_match_found} ->
          # Or it might not match at all
          assert true
      end
    end

    test "matches localized/foreign alternative titles", %{movie_with_alt_titles: movie} do
      # Update movie with a foreign alternative title
      {:ok, updated_movie} =
        Media.update_media_item(movie, %{
          metadata: %{
            "alternative_titles" => [
              "Live Die Repeat",
              "明日边缘"
            ]
          }
        })

      # Torrent using Chinese title
      torrent_info = %{
        type: :movie,
        title: "明日边缘",
        year: 2014
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == updated_movie.id
    end

    test "original_title is checked before alternative titles" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Professional",
          original_title: "Léon",
          year: 1994,
          tmdb_id: 101,
          metadata: %{
            "alternative_titles" => ["Leon: The Professional"]
          }
        })

      # Match using original title
      torrent_info = %{
        type: :movie,
        title: "Leon",
        year: 1994
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      # Should have high confidence as original_title is not penalized
      assert match.confidence >= 0.85
    end

    test "alternative titles are case-insensitive" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Source Code",
          year: 2011,
          tmdb_id: 45_612,
          metadata: %{
            "alternative_titles" => ["SOURCE CODE MOVIE"]
          }
        })

      torrent_info = %{
        type: :movie,
        title: "source code movie",
        year: 2011
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
    end

    test "duplicate alternative titles are handled correctly" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "The Matrix",
          original_title: "The Matrix",
          year: 1999,
          tmdb_id: 603,
          metadata: %{
            # Duplicate titles should be deduplicated by get_title_variants
            "alternative_titles" => [
              "The Matrix",
              "Matrix",
              "The Matrix"
            ]
          }
        })

      torrent_info = %{
        type: :movie,
        title: "Matrix",
        year: 1999
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == movie.id
      assert match.confidence >= 0.8
    end
  end

  describe "TV show short TVDB alias matching" do
    # A short alias ("Quiet Harbor" for the show's full "Quiet Harbor: The
    # Long Tide") is exactly the shape TVDB now contributes as an
    # alternative title. It has to still let a release named by that alias
    # match the show...
    setup do
      show =
        insert(:media_item, %{
          type: "tv_show",
          title: "Quiet Harbor: The Long Tide",
          monitored: true,
          metadata: %MediaMetadata{
            provider_id: "1",
            provider: :tvdb,
            media_type: :tv_show,
            alternative_titles: ["Quiet Harbor", "Harbor"]
          }
        })

      episode =
        insert(:episode, %{
          media_item: show,
          season_number: 1,
          episode_number: 3,
          title: "The Long Tide"
        })

      %{show: show, episode: episode}
    end

    test "matches a release named by the show's short alias", %{show: show, episode: episode} do
      torrent_info = %{
        type: :tv,
        title: "Quiet Harbor",
        season: 1,
        episode: 3
      }

      assert {:ok, match} = TorrentMatcher.find_match(torrent_info)
      assert match.media_item.id == show.id
      assert match.episode.id == episode.id
    end

    # ...but must not, at the same time, let an unrelated show that merely
    # shares one word with a short alias ("Harbor") clear the confidence bar
    # UntrackedMatcher uses to auto-adopt a file (0.9, higher than the
    # matcher's own 0.8 default because adoption relocates a file the
    # operator owns). "Harbor Watch" belongs to no item in this library.
    test "does not clear the auto-adoption confidence for an unrelated title sharing one alias word" do
      torrent_info = %{
        type: :tv,
        title: "Harbor Watch",
        season: 1,
        episode: 3
      }

      case TorrentMatcher.find_match(torrent_info, confidence_threshold: 0.9) do
        {:error, _reason} ->
          :ok

        {:ok, match} ->
          assert match.confidence < 0.9
      end
    end
  end
end
