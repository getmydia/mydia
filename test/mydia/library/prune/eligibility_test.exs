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
      media_item: movie,
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
          %{relative_path: "a.mkv", metadata: duration(6000.0)},
          %{relative_path: "b.mkv", metadata: duration(5900.0)}
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
end
