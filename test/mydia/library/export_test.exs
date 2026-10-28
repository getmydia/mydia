defmodule Mydia.Library.ExportTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.Export
  alias Mydia.Library.Export.{FileRow, Row}

  describe "rows/0" do
    test "returns an empty list for an empty library" do
      assert Export.rows() == []
    end

    test "a movie counts its version files and ignores trashed files and extras" do
      profile = quality_profile_fixture(%{name: "Crisp 1080"})

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "The Lantern Keeper",
          year: 2021,
          tmdb_id: 900_001,
          imdb_id: "tt9000001",
          quality_profile_id: profile.id
        })

      media_file_fixture(%{media_item_id: movie.id, size: 1_000})
      media_file_fixture(%{media_item_id: movie.id, size: 2_000})
      media_file_fixture(%{media_item_id: movie.id, size: 50, extra_kind: :trailer})

      trashed = media_file_fixture(%{media_item_id: movie.id, size: 9_999})
      {:ok, _} = Library.update_media_file(trashed, %{trashed_at: DateTime.utc_now()})

      assert [%Row{} = row] = Export.rows()
      assert row.type == "movie"
      assert row.title == "The Lantern Keeper"
      assert row.year == 2021
      assert row.tmdb_id == 900_001
      assert row.imdb_id == "tt9000001"
      assert row.quality_profile == "Crisp 1080"
      assert row.monitored == true
      assert row.file_count == 2
      assert row.size_bytes == 3_000
      assert row.episode_count == nil
      assert row.episodes_with_files == nil
      assert %DateTime{} = row.added_at
    end

    test "a show counts files reached through episodes (media_item_id is NULL on them)" do
      show = media_item_fixture(%{type: "tv_show", title: "Harbor of Echoes", tvdb_id: 800_001})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      _e3 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})

      f1 = media_file_fixture(%{episode_id: e1.id, size: 700})
      assert is_nil(f1.media_item_id)
      media_file_fixture(%{episode_id: e2.id, size: 300})

      assert [row] = Export.rows()
      assert row.type == "tv_show"
      assert row.tvdb_id == 800_001
      assert row.file_count == 2
      assert row.size_bytes == 1_000
      assert row.episode_count == 3
      assert row.episodes_with_files == 2
    end

    test "a multi-episode file counts once but covers every linked episode" do
      show = media_item_fixture(%{type: "tv_show", title: "Salt Road"})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      file = media_file_fixture(%{episode_id: e1.id, size: 500})
      Library.link_file_to_episodes(file, [e1, e2])

      assert [row] = Export.rows()
      assert row.file_count == 1
      assert row.size_bytes == 500
      assert row.episode_count == 2
      assert row.episodes_with_files == 2
    end

    test "an item with no files reports zeros and nil optional fields" do
      media_item_fixture(%{type: "movie", title: "Paper Comet"})

      assert [row] = Export.rows()
      assert row.file_count == 0
      assert row.size_bytes == 0
      assert row.tmdb_id == nil
      assert row.quality_profile == nil
    end

    test "carries the library path's root path" do
      lp = library_path_fixture(%{type: "movies"})
      media_item_fixture(%{type: "movie", title: "Quiet Tides", library_path_id: lp.id})

      assert [row] = Export.rows()
      assert row.library_path == lp.path
    end

    test "sorts by type, then case-insensitive title, then year" do
      media_item_fixture(%{type: "tv_show", title: "alpha Station"})
      media_item_fixture(%{type: "movie", title: "beacon", year: 2020})
      media_item_fixture(%{type: "movie", title: "Beacon", year: 2010})
      media_item_fixture(%{type: "movie", title: "Amber Field"})

      assert Enum.map(Export.rows(), &{&1.type, &1.title, &1.year}) == [
               {"movie", "Amber Field", 2024},
               {"movie", "Beacon", 2010},
               {"movie", "beacon", 2020},
               {"tv_show", "alpha Station", 2024}
             ]
    end
  end

  describe "rows/0 files" do
    test "a movie lists its version files with codec details from metadata.streams" do
      lp = library_path_fixture(%{type: "movies"})
      movie = media_item_fixture(%{type: "movie", title: "Velvet Meridian"})

      media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: lp.id,
        relative_path: "Velvet Meridian (2022)/Velvet Meridian (2022).MKV",
        size: 4_200,
        resolution: "2160p",
        codec: "hevc",
        audio_codec: "eac3",
        hdr_format: :hdr10,
        metadata: %{
          "duration" => 100.0,
          # The flat fields are never populated in production; the export must not read them.
          "bit_depth" => 8,
          "streams" => [
            %{
              "type" => "video",
              "index" => 0,
              "codec" => "hevc",
              "profile" => "Main 10",
              "bit_depth" => 10
            },
            %{
              "type" => "audio",
              "index" => 1,
              "codec" => "eac3",
              "channels" => 6,
              "channel_layout" => "5.1(side)"
            },
            %{
              "type" => "audio",
              "index" => 2,
              "codec" => "aac",
              "channels" => 2,
              "channel_layout" => "stereo"
            }
          ]
        }
      })

      media_file_fixture(%{media_item_id: movie.id, extra_kind: :trailer})
      trashed = media_file_fixture(%{media_item_id: movie.id})
      {:ok, _} = Library.update_media_file(trashed, %{trashed_at: DateTime.utc_now()})

      assert [row] = Export.rows()
      assert [%FileRow{} = file] = row.files

      assert file.path == Path.join(lp.path, "Velvet Meridian (2022)/Velvet Meridian (2022).MKV")
      assert file.library_path == lp.path
      assert file.size_bytes == 4_200
      assert file.resolution == "2160p"
      assert file.video_codec == "hevc"
      assert file.video_profile == "Main 10"
      assert file.bit_depth == 10
      assert file.hdr_format == "hdr10"
      assert file.audio_codec == "eac3"
      assert file.audio_channels == "5.1(side)"
      assert file.container == "mkv"
      assert file.season == nil
      assert file.episode == nil
    end

    test "missing stream data is nil and audio channels fall back to the channel count" do
      movie = media_item_fixture(%{type: "movie", title: "Thimble Lake"})

      media_file_fixture(%{
        media_item_id: movie.id,
        relative_path: "thimble",
        metadata: %{"duration" => 1.0, "streams" => [%{"type" => "audio", "channels" => 2}]}
      })

      assert [%{files: [file]}] = Export.rows()
      assert file.video_profile == nil
      assert file.bit_depth == nil
      assert file.hdr_format == nil
      assert file.audio_channels == "2"
      assert file.container == nil
    end

    test "the file's own library path is reported, not the item's" do
      item_lp = library_path_fixture(%{type: "movies"})
      file_lp = library_path_fixture(%{type: "movies"})

      movie =
        media_item_fixture(%{type: "movie", title: "Lowland Choir", library_path_id: item_lp.id})

      media_file_fixture(%{media_item_id: movie.id, library_path_id: file_lp.id})

      assert [row] = Export.rows()
      assert row.library_path == item_lp.path
      assert [file] = row.files
      assert file.library_path == file_lp.path
    end

    test "episode files land under their show, ordered by season and episode" do
      show = media_item_fixture(%{type: "tv_show", title: "Cinder Valley"})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})
      s2 = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 1})

      media_file_fixture(%{episode_id: s2.id, relative_path: "a/s2e1.mkv"})
      f1 = media_file_fixture(%{episode_id: e1.id, relative_path: "z/s1e1.mkv"})
      assert is_nil(f1.media_item_id)
      media_file_fixture(%{episode_id: e2.id, relative_path: "m/s1e2.mkv"})

      assert [row] = Export.rows()
      assert Enum.map(row.files, &{&1.season, &1.episode}) == [{1, "1"}, {1, "2"}, {2, "1"}]
    end

    test "a multi-episode file reports the episode range" do
      show = media_item_fixture(%{type: "tv_show", title: "Brass Orchard"})
      e1 = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 4})
      e2 = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 5})

      file = media_file_fixture(%{episode_id: e1.id})
      Library.link_file_to_episodes(file, [e1, e2])

      assert [%{files: [file_row]}] = Export.rows()
      assert file_row.season == 3
      assert file_row.episode == "4-5"
    end

    test "an item without files has an empty list" do
      media_item_fixture(%{type: "movie", title: "Fable of Dust"})
      assert [%{files: []}] = Export.rows()
    end
  end

  describe "to_json/1" do
    test "items carry a files array" do
      movie = media_item_fixture(%{type: "movie", title: "Copperline"})
      media_file_fixture(%{media_item_id: movie.id, relative_path: "Copperline.mp4", size: 77})

      decoded = Export.rows() |> Export.to_json() |> IO.iodata_to_binary() |> Jason.decode!()

      assert [%{"files" => [file]}] = decoded["items"]

      assert Map.keys(file) |> Enum.sort() ==
               FileRow.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      assert file["size_bytes"] == 77
      assert file["container"] == "mp4"
      assert String.ends_with?(file["path"], "/Copperline.mp4")
    end
  end

  describe "to_json/1 envelope" do
    setup do
      media_item_fixture(%{type: "movie", title: "Northwind, \"Redux\"", tmdb_id: 900_010})
      %{rows: Export.rows()}
    end

    test "wraps rows in a versioned envelope", %{rows: rows} do
      decoded = rows |> Export.to_json() |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["format"] == "mydia-library"
      assert decoded["version"] == 2
      assert decoded["mydia_version"] == Mydia.System.app_version()
      assert {:ok, _, _} = DateTime.from_iso8601(decoded["exported_at"])
      assert [item] = decoded["items"]
      assert item["type"] == "movie"
      assert item["tmdb_id"] == 900_010
      assert Map.has_key?(item, "tvdb_id") and is_nil(item["tvdb_id"])
      assert {:ok, _, _} = DateTime.from_iso8601(item["added_at"])
    end

    test "emits keys in column order", %{rows: rows} do
      json = rows |> Export.to_json() |> IO.iodata_to_binary()

      {:ok, envelope} = Jason.decode(json, objects: :ordered_objects)

      assert Enum.map(envelope.values, &elem(&1, 0)) ==
               ["format", "version", "exported_at", "mydia_version", "items"]

      [item] = envelope["items"]

      assert Enum.map(item.values, &elem(&1, 0)) ==
               Enum.map(Row.fields(), &Atom.to_string/1) ++ ["files"]
    end

    test "an empty library is a valid envelope" do
      decoded = [] |> Export.to_json() |> IO.iodata_to_binary() |> Jason.decode!()
      assert decoded["items"] == []
    end
  end

  describe "to_csv/1" do
    test "header row matches the column order and round-trips awkward values" do
      media_item_fixture(%{type: "movie", title: "Northwind, \"Redux\"\nPart Two"})
      media_item_fixture(%{type: "movie", title: "Été à Kyōto"})

      csv = Export.rows() |> Export.to_csv() |> IO.iodata_to_binary()

      refute String.starts_with?(csv, "﻿")
      assert String.contains?(csv, "\r\n")

      [header | rows] = NimbleCSV.RFC4180.parse_string(csv, skip_headers: false)
      assert header == Enum.map(Row.fields(), &Atom.to_string/1)

      titles = Enum.map(rows, &Enum.at(&1, 1))
      assert "Northwind, \"Redux\"\nPart Two" in titles
      assert "Été à Kyōto" in titles
    end

    test "nil is an empty cell and booleans are true/false" do
      media_item_fixture(%{type: "movie", title: "Glass Harbor", monitored: false})

      [_header, row] =
        Export.rows()
        |> Export.to_csv()
        |> IO.iodata_to_binary()
        |> NimbleCSV.RFC4180.parse_string(skip_headers: false)

      by_col = Enum.zip(Enum.map(Row.fields(), &Atom.to_string/1), row) |> Map.new()
      assert by_col["tmdb_id"] == ""
      assert by_col["monitored"] == "false"
      assert by_col["episode_count"] == ""
    end

    test "an empty library is a header-only CSV" do
      csv = [] |> Export.to_csv() |> IO.iodata_to_binary()
      assert csv == Enum.map_join(Row.fields(), ",", &Atom.to_string/1) <> "\r\n"
    end
  end

  describe "to_files_csv/1" do
    @identity ~w(type title year tmdb_id tvdb_id imdb_id)

    test "one row per file, item identity first, awkward paths quoted" do
      movie =
        media_item_fixture(%{type: "movie", title: "Kestrel Bay", year: 2019, tmdb_id: 900_030})

      media_file_fixture(%{media_item_id: movie.id, relative_path: "Kestrel, \"Bay\".mkv"})
      media_file_fixture(%{media_item_id: movie.id, relative_path: "Kestrel Bay.mp4"})
      media_item_fixture(%{type: "movie", title: "No Files Here"})

      csv = Export.rows() |> Export.to_files_csv() |> IO.iodata_to_binary()
      assert csv =~ ~r/,"[^,"]*Kestrel, ""Bay"".mkv",/

      [header | rows] = NimbleCSV.RFC4180.parse_string(csv, skip_headers: false)
      assert header == @identity ++ Enum.map(FileRow.fields(), &Atom.to_string/1)
      assert length(rows) == 2

      cells = Enum.map(rows, &Map.new(Enum.zip(header, &1)))
      assert Enum.all?(cells, &(&1["title"] == "Kestrel Bay" and &1["tmdb_id"] == "900030"))
      assert Enum.any?(cells, &String.ends_with?(&1["path"], "Kestrel, \"Bay\".mkv"))
      assert Enum.all?(cells, &(&1["season"] == "" and &1["tvdb_id"] == ""))
    end

    test "an empty library is a header-only CSV" do
      csv = [] |> Export.to_files_csv() |> IO.iodata_to_binary()

      assert csv ==
               Enum.join(@identity ++ Enum.map(FileRow.fields(), &Atom.to_string/1), ",") <>
                 "\r\n"
    end
  end

  describe "filename/2" do
    test "uses the UTC date and the format extension" do
      at = ~U[2026-09-24 23:30:00Z]
      assert Export.filename(:json, at) == "mydia-library-2026-09-24.json"
      assert Export.filename(:csv, at) == "mydia-library-2026-09-24.csv"
      assert Export.filename(:files_csv, at) == "mydia-library-files-2026-09-24.csv"
    end
  end
end
