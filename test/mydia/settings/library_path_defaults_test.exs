defmodule Mydia.Settings.LibraryPathDefaultsTest do
  # async: false — the env configuration describe mutates System env
  # (same hazard as test/mydia/config/loader_test.exs).
  use Mydia.DataCase, async: false

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

  describe "backfill" do
    # Migration modules are not compiled into the app, so load the file explicitly.
    Code.require_file("priv/repo/migrations/20260811173217_backfill_default_library_flags.exs")

    alias Mydia.Repo.Migrations.BackfillDefaultLibraryFlags, as: Backfill

    test "flags the oldest monitored library of each kind" do
      older = library_path_fixture(%{type: "movies"})
      newer = library_path_fixture(%{type: "movies"})
      series = library_path_fixture(%{type: "series"})

      # library_path_fixture inserts in call order, so `older` has the earlier
      # inserted_at. Force a gap so the ordering is unambiguous under a
      # second-resolution timestamp column.
      backdate(older, ~U[2020-01-01 00:00:00Z])
      backdate(newer, ~U[2021-01-01 00:00:00Z])
      backdate(series, ~U[2020-01-01 00:00:00Z])

      Backfill.backfill()

      assert Mydia.Repo.get!(LibraryPath, older.id).default_for_movies
      refute Mydia.Repo.get!(LibraryPath, newer.id).default_for_movies
      assert Mydia.Repo.get!(LibraryPath, series.id).default_for_series
    end

    test "does not overwrite an existing flag" do
      older = library_path_fixture(%{type: "movies"})
      newer = library_path_fixture(%{type: "movies"})
      backdate(older, ~U[2020-01-01 00:00:00Z])
      backdate(newer, ~U[2021-01-01 00:00:00Z])

      {:ok, _} = Settings.set_default_library(newer, :movies)

      Backfill.backfill()

      assert Mydia.Repo.get!(LibraryPath, newer.id).default_for_movies
      refute Mydia.Repo.get!(LibraryPath, older.id).default_for_movies
    end

    test "skips unmonitored libraries" do
      unmonitored = library_path_fixture(%{type: "movies", monitored: false})
      monitored = library_path_fixture(%{type: "movies"})
      backdate(unmonitored, ~U[2020-01-01 00:00:00Z])
      backdate(monitored, ~U[2021-01-01 00:00:00Z])

      Backfill.backfill()

      assert Mydia.Repo.get!(LibraryPath, monitored.id).default_for_movies
      refute Mydia.Repo.get!(LibraryPath, unmonitored.id).default_for_movies
    end

    test "is a no-op when there are no libraries" do
      assert Backfill.backfill() == :ok
      assert Settings.default_library_for(:movies) == nil
    end

    defp backdate(library_path, at) do
      import Ecto.Query

      Mydia.Repo.update_all(
        from(l in LibraryPath, where: l.id == ^library_path.id),
        set: [inserted_at: at]
      )
    end
  end

  describe "env configuration" do
    # Matches loader_test isolation: put_env + on_exit cleanup, assert on the
    # validated config struct (not the raw env map).
    test "LIBRARY_PATH_<N>_DEFAULT_FOR_MOVIES is parsed" do
      System.put_env("LIBRARY_PATH_1_PATH", "/tmp/env-movies")
      System.put_env("LIBRARY_PATH_1_TYPE", "movies")
      System.put_env("LIBRARY_PATH_1_DEFAULT_FOR_MOVIES", "true")

      on_exit(fn ->
        System.delete_env("LIBRARY_PATH_1_PATH")
        System.delete_env("LIBRARY_PATH_1_TYPE")
        System.delete_env("LIBRARY_PATH_1_DEFAULT_FOR_MOVIES")
      end)

      {:ok, config} = Mydia.Config.Loader.load(config_file: "nonexistent.yml")
      entry = Enum.find(config.library_paths, &(&1.path == "/tmp/env-movies"))

      assert entry.default_for_movies == true
    end
  end
end
