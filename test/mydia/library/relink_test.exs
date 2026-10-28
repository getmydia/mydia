defmodule Mydia.Library.RelinkTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.{MediaFile, Relink}
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  @lp %LibraryPath{id: "lp-a", path: "/lib"}

  defp gone(id, rel, size),
    do: %MediaFile{id: id, relative_path: rel, size: size, library_path: @lp}

  defp found(path, size), do: %{path: path, size: size}

  describe "pair/2" do
    test "pairs a rename in the same directory" do
      g = gone("1", "Paper Lanterns (2011)/Paper.Lanterns.2011.mkv", 900)
      f = found("/lib/Paper Lanterns (2011)/Paper Lanterns (2011).mkv", 900)
      assert {[{^g, ^f}], [], []} = Relink.pair([g], [f])
    end

    test "pairs a move that keeps the file name" do
      g = gone("1", "Paper Lanterns (2011)/Paper Lanterns (2011).mkv", 900)
      f = found("/other/Paper Lanterns (2011)/Paper Lanterns (2011).mkv", 900)
      assert {[{^g, ^f}], [], []} = Relink.pair([g], [f])
    end

    test "does not pair when sizes differ" do
      g = gone("1", "A/x.mkv", 900)
      f = found("/lib/A/y.mkv", 901)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end

    test "does not pair a different name in a different directory" do
      g = gone("1", "A/x.mkv", 900)
      f = found("/lib/B/y.mkv", 900)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end

    test "refuses an ambiguous match on either side" do
      g1 = gone("1", "A/x.mkv", 900)
      g2 = gone("2", "A/z.mkv", 900)
      f = found("/lib/A/y.mkv", 900)
      assert {[], gone_left, [^f]} = Relink.pair([g1, g2], [f])
      assert Enum.sort_by(gone_left, & &1.id) == [g1, g2]

      f2 = found("/lib/A/w.mkv", 900)
      assert {[], [^g1], found_left} = Relink.pair([g1], [f, f2])
      assert length(found_left) == 2
    end

    test "refuses a rename that changes the episode number" do
      g = gone("1", "Tidewater Hollow/Season 01/Tidewater.Hollow.S01E01.mkv", 900)
      f = found("/lib/Tidewater Hollow/Season 01/Tidewater.Hollow.S01E02.mkv", 900)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end

    test "refuses a rename that changes the season" do
      g = gone("1", "Tidewater Hollow/Tidewater.Hollow.S01E03.mkv", 900)
      f = found("/lib/Tidewater Hollow/Tidewater.Hollow.S02E03.mkv", 900)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end

    test "pairs a rename that keeps the same episode" do
      g = gone("1", "Tidewater Hollow/Season 01/Tidewater.Hollow.S01E01.720p.mkv", 900)
      f = found("/lib/Tidewater Hollow/Season 01/Tidewater Hollow - S01E01 - Pilot.mkv", 900)
      assert {[{^g, ^f}], [], []} = Relink.pair([g], [f])
    end

    test "pairs when only one side names an episode" do
      g = gone("1", "Tidewater Hollow/Season 01/episode one.mkv", 900)
      f = found("/lib/Tidewater Hollow/Season 01/Tidewater.Hollow.S01E01.mkv", 900)
      assert {[{^g, ^f}], [], []} = Relink.pair([g], [f])
    end

    test "never pairs a row whose bytes are in the trash directory" do
      g = %{
        gone("1", "A/x.mkv", 900)
        | trashed_reason: :missing,
          metadata: %FileMetadata{extra: %{"trashed_path" => "/lib/.mydia-trash/1/x.mkv"}}
      }

      f = found("/lib/A/y.mkv", 900)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end

    test "skips rows with no size or no resolvable path" do
      g = %MediaFile{id: "1", relative_path: "A/x.mkv", size: nil, library_path: @lp}
      f = found("/lib/A/y.mkv", 900)
      assert {[], [^g], [^f]} = Relink.pair([g], [f])
    end
  end

  describe "relink/3 and relink_all/2" do
    defp setup_file(rel) do
      lp = library_path_fixture()
      file = media_file_fixture(%{library_path_id: lp.id, relative_path: rel, size: 500})
      {lp, file}
    end

    test "repoints an active row and keeps its dependents" do
      {lp, file} = setup_file("A/old.mkv")

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: file.id,
          language: "en",
          provider: "test",
          subtitle_hash: "h1",
          file_path: "/tmp/x.srt",
          format: "srt"
        })
        |> Repo.insert()

      info = %{path: Path.join(lp.path, "A/new.mkv"), size: 777}
      assert {:ok, updated} = Relink.relink(file, info, lp)

      assert updated.id == file.id
      assert updated.relative_path == "A/new.mkv"
      assert updated.size == 777
      assert %DateTime{} = updated.verified_at
      assert Repo.get!(Subtitle, subtitle.id).media_file_id == file.id
    end

    test "clears a missing trash state" do
      {lp, file} = setup_file("A/old.mkv")

      {:ok, trashed} =
        file
        |> Ecto.Changeset.change(
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          trashed_reason: :missing,
          metadata: %{
            file.metadata
            | extra: Map.put(file.metadata.extra, "trashed_missing", true)
          }
        )
        |> Repo.update()

      info = %{path: Path.join(lp.path, "A/new.mkv"), size: 500}
      assert {:ok, updated} = Relink.relink(trashed, info, lp)
      assert is_nil(updated.trashed_at)
      assert is_nil(updated.trashed_reason)
      refute Map.has_key?(updated.metadata.extra, "trashed_missing")

      reloaded = Repo.get!(MediaFile, file.id)
      assert is_nil(reloaded.trashed_at)
      refute Map.has_key?(reloaded.metadata.extra, "trashed_missing")
    end

    test "moves a row across libraries" do
      {_lp_a, file} = setup_file("A/old.mkv")
      lp_b = library_path_fixture()
      info = %{path: Path.join(lp_b.path, "B/old.mkv"), size: 500}

      assert {:ok, updated} = Relink.relink(file, info, lp_b)
      assert updated.library_path_id == lp_b.id
      assert updated.relative_path == "B/old.mkv"
    end

    test "returns an error instead of raising when the target path is occupied" do
      {lp, file} = setup_file("A/old.mkv")
      media_file_fixture(%{library_path_id: lp.id, relative_path: "A/new.mkv"})
      info = %{path: Path.join(lp.path, "A/new.mkv"), size: 500}

      assert {:error, %Ecto.Changeset{}} = Relink.relink(file, info, lp)

      file = Repo.preload(file, :library_path)
      assert {[], [{^file, ^info}]} = Relink.relink_all([{file, info}], [lp])
    end

    test "relink_all splits relinked from failed" do
      {lp, file} = setup_file("A/old.mkv")
      file = Repo.preload(file, :library_path)
      info = %{path: Path.join(lp.path, "A/new.mkv"), size: 500}

      assert {[{^file, ^info}], []} = Relink.relink_all([{file, info}], [lp])
      assert Repo.get!(MediaFile, file.id).relative_path == "A/new.mkv"
    end
  end
end
