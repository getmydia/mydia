defmodule Mydia.Settings.LibraryPathDefaultsTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  describe "changeset type compatibility" do
    test "rejects default_for_series on a movies library" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/tmp/only-movies",
          type: "movies",
          default_for_series: true
        })

      refute changeset.valid?
      assert %{default_for_series: [_ | _]} = errors_on(changeset)
    end

    test "rejects default_for_movies on a series library" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/tmp/only-series",
          type: "series",
          default_for_movies: true
        })

      refute changeset.valid?
      assert %{default_for_movies: [_ | _]} = errors_on(changeset)
    end

    test "allows both flags on a mixed library" do
      changeset =
        LibraryPath.changeset(%LibraryPath{}, %{
          path: "/tmp/mixed",
          type: "mixed",
          default_for_movies: true,
          default_for_series: true
        })

      assert changeset.valid?
    end
  end

  describe "set_default_library/2" do
    test "moves the flag off whatever row held it" do
      first = library_path_fixture(%{type: "movies"})
      second = library_path_fixture(%{type: "movies"})

      {:ok, _} = Settings.set_default_library(first, :movies)
      {:ok, _} = Settings.set_default_library(second, :movies)

      refute Mydia.Repo.get!(LibraryPath, first.id).default_for_movies
      assert Mydia.Repo.get!(LibraryPath, second.id).default_for_movies
    end

    test "refuses a kind the library type cannot serve" do
      series = library_path_fixture(%{type: "series"})

      assert {:error, :incompatible_type} = Settings.set_default_library(series, :movies)
    end

    test "setting the movies default leaves the series default alone" do
      movies = library_path_fixture(%{type: "movies"})
      series = library_path_fixture(%{type: "series"})

      {:ok, _} = Settings.set_default_library(series, :series)
      {:ok, _} = Settings.set_default_library(movies, :movies)

      assert Mydia.Repo.get!(LibraryPath, series.id).default_for_series
      assert Mydia.Repo.get!(LibraryPath, movies.id).default_for_movies
    end
  end

  describe "default_library_for/1" do
    test "returns nil when nothing is flagged" do
      library_path_fixture(%{type: "movies"})

      assert Settings.default_library_for(:movies) == nil
    end

    test "returns the flagged library" do
      library = library_path_fixture(%{type: "movies"})
      {:ok, _} = Settings.set_default_library(library, :movies)

      assert Settings.default_library_for(:movies).id == library.id
    end

    test "ignores a disabled flagged library" do
      library = library_path_fixture(%{type: "movies"})
      {:ok, library} = Settings.set_default_library(library, :movies)
      {:ok, _} = Settings.update_library_path(library, %{disabled: true})

      assert Settings.default_library_for(:movies) == nil
    end
  end
end
