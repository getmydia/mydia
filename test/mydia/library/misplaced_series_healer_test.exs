defmodule Mydia.Library.MisplacedSeriesHealerTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.MisplacedSeriesHealer
  alias Mydia.Settings

  import Mydia.MediaFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    series_root = Path.join(tmp_dir, "Series")
    File.mkdir_p!(series_root)

    {:ok, library_path} =
      Settings.create_library_path(%{
        path: series_root,
        type: :series,
        monitored: true
      })

    %{series_root: series_root, library_path: library_path}
  end

  test "relocates a foreign file into the matching show folder", %{
    series_root: series_root,
    library_path: library_path
  } do
    _silo = media_item_fixture(%{type: "tv_show", title: "Silo", year: 2023})
    _morty = media_item_fixture(%{type: "tv_show", title: "Rick and Morty", year: 2013})

    silo_season = Path.join([series_root, "Silo", "Season 03"])
    File.mkdir_p!(silo_season)

    misplaced =
      Path.join(
        silo_season,
        "Rick.and.Morty.S09E01.Theres.Something.About.Morty.1080p.mkv"
      )

    File.write!(misplaced, "morty episode")

    result = MisplacedSeriesHealer.heal(library_path_id: library_path.id)

    assert result.relocated == 1
    refute File.exists?(misplaced)

    dest =
      Path.join([
        series_root,
        "Rick and Morty",
        "Season 09",
        "Rick.and.Morty.S09E01.Theres.Something.About.Morty.1080p.mkv"
      ])

    assert File.exists?(dest)
  end

  test "quarantines foreign files with no matching library show", %{
    series_root: series_root,
    library_path: library_path
  } do
    _silo = media_item_fixture(%{type: "tv_show", title: "Silo", year: 2023})

    silo_season = Path.join([series_root, "Silo", "Season 01"])
    File.mkdir_p!(silo_season)

    orphan = Path.join(silo_season, "Star.Trek.TOS.S01E01.The.Man.Trap.avi")
    File.write!(orphan, "trek episode")

    result = MisplacedSeriesHealer.heal(library_path_id: library_path.id)

    assert result.quarantined == 1
    refute File.exists?(orphan)

    assert File.exists?(
             Path.join([
               series_root,
               "_misplaced",
               "Silo",
               "Season 01",
               "Star.Trek.TOS.S01E01.The.Man.Trap.avi"
             ])
           )
  end

  test "leaves correctly placed files alone", %{
    series_root: series_root,
    library_path: library_path
  } do
    _silo = media_item_fixture(%{type: "tv_show", title: "Silo", year: 2023})

    silo_season = Path.join([series_root, "Silo", "Season 01"])
    File.mkdir_p!(silo_season)

    good = Path.join(silo_season, "Silo.S01E01.Pilot.1080p.mkv")
    File.write!(good, "silo episode")

    result = MisplacedSeriesHealer.heal(library_path_id: library_path.id)

    assert result.relocated == 0
    assert result.quarantined == 0
    assert File.exists?(good)
  end

  test "dry_run reports without moving", %{
    series_root: series_root,
    library_path: library_path
  } do
    _silo = media_item_fixture(%{type: "tv_show", title: "Silo", year: 2023})

    silo_season = Path.join([series_root, "Silo", "Season 01"])
    File.mkdir_p!(silo_season)

    orphan = Path.join(silo_season, "Star.Trek.TOS.S01E01.The.Man.Trap.avi")
    File.write!(orphan, "trek episode")

    result = MisplacedSeriesHealer.heal(library_path_id: library_path.id, dry_run: true)

    assert result.quarantined == 1
    assert File.exists?(orphan)
  end
end
