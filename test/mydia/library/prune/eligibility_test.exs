defmodule Mydia.Library.Prune.EligibilityTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Prune.{Eligibility, Group}

  # Builds a movie group whose files differ only in the attrs given.
  defp movie_group(file_attrs) do
    movie = media_item_fixture(%{type: "movie", title: "Muppets Most Wanted", year: 2014})
    lp = library_path_fixture(%{type: "movies"})

    files =
      Enum.map(file_attrs, fn attrs ->
        attrs
        |> Map.merge(%{media_item_id: movie.id, library_path_id: lp.id})
        |> media_file_fixture()
      end)

    files = Mydia.Repo.preload(files, :library_path)

    %Group{
      subject_type: :movie,
      subject_id: movie.id,
      subject: movie,
      media_item: Mydia.Repo.preload(movie, :episodes),
      files: files
    }
  end

  defp duration(seconds), do: %{"container" => "mkv", "duration" => seconds}

  describe "check/1 duplicate registration" do
    test "refuses two rows sharing library_path_id and relative_path" do
      group =
        movie_group([
          %{relative_path: "Muppets/Muppets.mkv", metadata: duration(6000.0)},
          %{relative_path: "Muppets/Muppets.mkv", metadata: duration(6000.0)}
        ])

      assert {:refused, :duplicate_registration, detail} = Eligibility.check(group)
      assert detail.path == "Muppets/Muppets.mkv"
    end
  end

  describe "check/1 analysis" do
    test "refuses when any file has no duration" do
      group =
        movie_group([
          %{relative_path: "a.mkv", metadata: duration(6000.0)},
          %{relative_path: "b.avi", metadata: %{"container" => "avi"}}
        ])

      assert {:refused, :unanalyzed, detail} = Eligibility.check(group)
      assert detail.unanalyzed_count == 1
    end

    test "refuses a zero duration rather than dividing by it" do
      group =
        movie_group([
          %{relative_path: "a.mkv", metadata: duration(0.0)},
          %{relative_path: "b.mkv", metadata: duration(6000.0)}
        ])

      assert {:refused, :unanalyzed, _} = Eligibility.check(group)
    end
  end

  describe "check/1 duration agreement" do
    test "refuses the Monsters University extras shape" do
      group =
        movie_group([
          %{relative_path: "MU/Monsters University (2013).mkv", metadata: duration(6360.0)},
          %{relative_path: "MU/Campus Life.mkv", metadata: duration(280.0)}
        ])

      assert {:refused, :duration_mismatch, detail} = Eligibility.check(group)
      assert detail.spread > 0.02
    end

    test "refuses the cross-show shape" do
      group =
        movie_group([
          %{relative_path: "Comme des tetes/S03E24.mkv", metadata: duration(1405.0)},
          %{relative_path: "Les mots/S03E24.mkv", metadata: duration(120.0)}
        ])

      assert {:refused, :duration_mismatch, _} = Eligibility.check(group)
    end

    test "accepts durations inside the 2 percent tolerance" do
      group =
        movie_group([
          %{
            relative_path: "Muppets Most Wanted (2014) 1080p.mkv",
            metadata: duration(6000.0)
          },
          %{
            relative_path: "Muppets Most Wanted (2014) 720p.mkv",
            metadata: duration(5900.0)
          }
        ])

      assert {:ok, ^group} = Eligibility.check(group)
    end

    test "refuses durations just outside the 2 percent tolerance" do
      group =
        movie_group([
          %{relative_path: "a.mkv", metadata: duration(6000.0)},
          %{relative_path: "b.mkv", metadata: duration(5800.0)}
        ])

      assert {:refused, :duration_mismatch, _} = Eligibility.check(group)
    end
  end

  describe "check/1 empty group" do
    test "refuses nothing_to_prune instead of raising on an empty file list" do
      group = movie_group([])

      assert {:refused, :nothing_to_prune, %{count: 0}} = Eligibility.check(group)
    end
  end

  describe "check/1 refusal ordering" do
    test "reports duplicate_registration ahead of duration agreement" do
      # Identical rows trivially agree on duration. The scanner bug is the
      # more actionable reason, so it must win.
      group =
        movie_group([
          %{relative_path: "same.mkv", metadata: duration(6000.0)},
          %{relative_path: "same.mkv", metadata: duration(6000.0)}
        ])

      assert {:refused, :duplicate_registration, _} = Eligibility.check(group)
    end
  end

  describe "check/1 name agreement" do
    test "refuses the FROM Fray/Crepe shape where two names disagree" do
      show = media_item_fixture(%{type: "tv_show", title: "FROM", year: 2022})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 4, episode_number: 2})
      lp = library_path_fixture(%{type: "series"})

      files =
        for name <- [
              "FROM/Season 04/From.S04E02.Fray.WEB-DL.1080p.UkrEng.mkv",
              "FROM/Season 04/From.S04E03.Crepe.1080p.AMZN.WEB-DL.H.264-MeM.mkv"
            ] do
          media_file_fixture(%{
            episode_id: episode.id,
            library_path_id: lp.id,
            relative_path: name,
            metadata: %{"container" => "mkv", "duration" => 3246.0}
          })
        end

      group = %Group{
        subject_type: :episode,
        subject_id: episode.id,
        subject: episode,
        media_item: Mydia.Repo.preload(show, :episodes),
        files: Mydia.Repo.preload(files, :library_path)
      }

      assert {:refused, reason, _detail} = Eligibility.check(group)
      assert reason in [:name_mismatch, :episode_mismatch]
    end

    test "accepts two releases of the same episode" do
      show = media_item_fixture(%{type: "tv_show", title: "Rick and Morty", year: 2013})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
      lp = library_path_fixture(%{type: "series"})

      files =
        for name <- [
              "Rick and Morty/Season 02/Rick.and.Morty.S02E03.1080p.BluRay.x265-RARBG.mp4",
              "Rick and Morty/Season 02/Rick.and.Morty.S02E03.480p.WEBRip.x264.mp4"
            ] do
          media_file_fixture(%{
            episode_id: episode.id,
            library_path_id: lp.id,
            relative_path: name,
            metadata: %{"container" => "mp4", "duration" => 1320.0}
          })
        end

      group = %Group{
        subject_type: :episode,
        subject_id: episode.id,
        subject: episode,
        media_item: Mydia.Repo.preload(show, :episodes),
        files: Mydia.Repo.preload(files, :library_path)
      }

      assert {:ok, ^group} = Eligibility.check(group)
    end

    test "recovers the season from folder structure when the filename omits it" do
      # "E05" alone is anime-style absolute episode numbering with no season
      # marker: ReleaseParser.parse/2 on the basename defaults it to season 1
      # (see Resolver.parse_absolute_episode/1), which disagrees with this
      # episode's real season 3. Only the "Season 03" folder segment carries
      # the true season, and only ReleaseParser.parse_with_path/2 (fed
      # file.relative_path, not Path.basename/1) reads it. Before switching
      # check_episode_numbers/1 to parse_with_path/2, this exact shape parsed
      # season 1 from the basename and wrongly refused an eligible group as
      # :episode_mismatch.
      show = media_item_fixture(%{type: "tv_show", title: "Show Name"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 5})
      lp = library_path_fixture(%{type: "series"})

      files =
        for name <- [
              "Show Name/Season 03/Show.Name.E05.1080p.WEB.mkv",
              "Show Name/Season 03/Show.Name.E05.720p.WEB.mkv"
            ] do
          media_file_fixture(%{
            episode_id: episode.id,
            library_path_id: lp.id,
            relative_path: name,
            metadata: %{"container" => "mkv", "duration" => 1320.0}
          })
        end

      group = %Group{
        subject_type: :episode,
        subject_id: episode.id,
        subject: episode,
        media_item: Mydia.Repo.preload(show, :episodes),
        files: Mydia.Repo.preload(files, :library_path)
      }

      assert {:ok, ^group} = Eligibility.check(group)
    end
  end
end
