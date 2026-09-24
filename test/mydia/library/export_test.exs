defmodule Mydia.Library.ExportTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Library.Export
  alias Mydia.Library.Export.Row

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

  describe "to_json/1" do
    setup do
      media_item_fixture(%{type: "movie", title: "Northwind, \"Redux\"", tmdb_id: 900_010})
      %{rows: Export.rows()}
    end

    test "wraps rows in a versioned envelope", %{rows: rows} do
      decoded = rows |> Export.to_json() |> IO.iodata_to_binary() |> Jason.decode!()

      assert decoded["format"] == "mydia-library"
      assert decoded["version"] == 1
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
      assert Enum.map(item.values, &elem(&1, 0)) == Enum.map(Row.fields(), &Atom.to_string/1)
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

  describe "filename/2" do
    test "uses the UTC date and the format extension" do
      at = ~U[2026-09-24 23:30:00Z]
      assert Export.filename(:json, at) == "mydia-library-2026-09-24.json"
      assert Export.filename(:csv, at) == "mydia-library-2026-09-24.csv"
    end
  end
end
