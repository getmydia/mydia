defmodule Mydia.Settings.LibraryPathTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.LibraryPath

  describe "changeset/2" do
    test "auto_rename defaults to true" do
      library_path = %LibraryPath{}
      assert library_path.auto_rename == true
    end

    test "accepts auto_rename in changeset" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/media/movies",
          type: "movies",
          auto_rename: false
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :auto_rename) == false
    end

    test "auto_rename can be toggled back to true" do
      changeset =
        LibraryPath.changeset(%LibraryPath{auto_rename: false}, %{
          path: "/media/movies",
          type: "movies",
          auto_rename: true
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :auto_rename) == true
    end

    test "tv_metadata_source defaults to :tvdb" do
      assert %LibraryPath{}.tv_metadata_source == :tvdb
    end

    test "accepts :tmdb as tv_metadata_source" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/media/anime",
          type: "series",
          tv_metadata_source: :tmdb
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :tv_metadata_source) == :tmdb
    end

    test "accepts :tvdb as tv_metadata_source" do
      changeset =
        LibraryPath.changeset(%LibraryPath{tv_metadata_source: :tmdb}, %{
          path: "/media/series",
          type: "series",
          tv_metadata_source: :tvdb
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :tv_metadata_source) == :tvdb
    end

    test "rejects an unknown tv_metadata_source" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/media/series",
          type: "series",
          tv_metadata_source: "imdb"
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :tv_metadata_source)
    end

    test "defaults to :tvdb when omitted from attrs" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{path: "/media/series", type: "series"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :tv_metadata_source) == :tvdb
    end
  end

  describe "scan_interval validation" do
    defp base_attrs do
      %{path: "/media/movies", type: :movies}
    end

    test "defaults to nil, meaning manual only" do
      assert %LibraryPath{}.scan_interval == nil
    end

    test "accepts nil (automatic scanning off)" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, Map.put(base_attrs(), :scan_interval, nil))

      assert changeset.valid?
    end

    test "accepts the 900 second minimum" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, Map.put(base_attrs(), :scan_interval, 900))

      assert changeset.valid?
    end

    test "rejects an interval below 900 seconds" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, Map.put(base_attrs(), :scan_interval, 360))

      refute changeset.valid?
      assert "must be greater than or equal to 900" in errors_on(changeset).scan_interval
    end

    test "casts an empty string to nil so the Off option round-trips from the form" do
      changeset = LibraryPath.changeset(%LibraryPath{}, Map.put(base_attrs(), :scan_interval, ""))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :scan_interval) == nil
    end
  end
end
