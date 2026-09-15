defmodule Mydia.Library.RescanSeriesTest do
  use Mydia.DataCase

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "mydia_rescan_series_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    library_path = library_path_fixture(%{path: tmp, type: "series"})

    show =
      media_item_fixture(%{type: "tv_show", title: "Lantern Coast", year: 2019, tvdb_id: 900_001})

    # refresh_episodes_for_tv_show/2 resolves the provider from tvdb_id and then
    # honours the season-refresh throttle, so a fresh stamp keeps the re-scan
    # off the network.
    Media.stamp_seasons_refreshed(show)

    episodes =
      Map.new(1..3, fn n ->
        {n, episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: n})}
      end)

    existing = write_file(tmp, "Lantern Coast/Season 01/Lantern.Coast.S01E01.1080p.mkv")

    {:ok, _} =
      Library.create_media_file(%{
        relative_path: existing,
        library_path_id: library_path.id,
        episode_id: episodes[1].id,
        size: 10
      })

    %{tmp: tmp, library_path: library_path, show: show, episodes: episodes}
  end

  defp write_file(tmp, relative_path) do
    absolute = Path.join(tmp, relative_path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "0123456789")
    relative_path
  end

  defp row_at(library_path, relative_path) do
    Repo.get_by(MediaFile, library_path_id: library_path.id, relative_path: relative_path)
  end

  test "rescan_series/1 attaches a new file to every episode it names", ctx do
    relative = write_file(ctx.tmp, "Lantern Coast/Season 01/Lantern.Coast.S01E02E03.1080p.mkv")

    assert {:ok, result} = Library.rescan_series(ctx.show.id)
    assert result.new_files == 1
    assert result.matched == 1
    assert result.staged == 0

    file = row_at(ctx.library_path, relative)
    assert file.episode_id == ctx.episodes[2].id
    assert is_nil(file.media_item_id)

    assert [%MediaFile{id: covered}] = Repo.preload(ctx.episodes[3], :media_files).media_files
    assert covered == file.id
  end

  test "rescan_series/1 stages a file that names no episode instead of attaching it to the show",
       ctx do
    relative = write_file(ctx.tmp, "Lantern Coast/Season 01/Lantern.Coast.S01E09.1080p.mkv")

    assert {:ok, result} = Library.rescan_series(ctx.show.id)
    assert result.new_files == 0
    assert result.staged == 1

    assert is_nil(row_at(ctx.library_path, relative))

    candidate = ImportCandidates.get_by_path(ctx.library_path.id, relative)
    assert candidate.media_type == "tv_show"
    assert {candidate.provider_type, candidate.provider_id} == {"tvdb", "900001"}
  end

  test "rescan_season/2 attaches a new file for that season", ctx do
    relative = write_file(ctx.tmp, "Lantern Coast/Season 01/Lantern.Coast.S01E02.1080p.mkv")

    assert {:ok, result} = Library.rescan_season(ctx.show.id, 1)
    assert result.new_files == 1
    assert result.staged == 0
    assert row_at(ctx.library_path, relative).episode_id == ctx.episodes[2].id
  end
end
