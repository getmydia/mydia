defmodule Mydia.Demo.LibraryTest do
  # async: false because the stub provider is registered process-globally.
  use Mydia.DataCase, async: false

  alias Mydia.Demo.Library
  alias Mydia.DemoMetadataStubProvider, as: Stub
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.Progress
  alias Mydia.Settings.{LibraryPath, LibraryPaths}

  defp write_titles(tmp_dir, lines) do
    path = Path.join(tmp_dir, "titles.local")
    File.write!(path, Enum.join(lines, "\n"))
    path
  end

  defp catalog_lines do
    ["# demo list, comments name titles"] ++
      Enum.map(Stub.movie_ids(), &"movie #{&1}  # a movie") ++
      [""] ++ Enum.map(Stub.show_ids(), &"tv #{&1}")
  end

  defp counts do
    {Repo.aggregate(MediaItem, :count), Repo.aggregate(Episode, :count),
     Repo.aggregate(MediaFile, :count), Repo.aggregate(Progress, :count)}
  end

  describe "parse_titles/1" do
    test "reads movie and tv entries, skipping comments and blank lines" do
      assert {:ok, [{:movie, 12}, {:tv, 34}]} =
               Library.parse_titles("# header\nmovie 12 # name\n\n  tv 34\n")
    end

    test "rejects an unknown kind or a non-numeric id" do
      assert {:error, {:invalid_line, 2, "show 5"}} = Library.parse_titles("movie 1\nshow 5")
      assert {:error, {:invalid_line, 1, "movie abc"}} = Library.parse_titles("movie abc")
    end

    test "rejects a list with no entries" do
      assert {:error, :no_titles} = Library.parse_titles("# nothing yet\n")
    end
  end

  describe "seed/1" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      :ok = Stub.setup()
      user = insert(:user, role: "admin")
      {:ok, user: user, titles: write_titles(tmp_dir, catalog_lines())}
    end

    defp seed(ctx, opts \\ []), do: Library.seed([titles: ctx.titles, user: ctx.user] ++ opts)

    test "seeds every listed title with its fetched metadata", ctx do
      assert {:ok, %{movies: 3, shows: 2, episodes: episodes}} = seed(ctx)

      items = Repo.all(MediaItem)
      assert length(items) == 5
      assert Enum.sort(Enum.map(items, & &1.title)) == Enum.sort(Stub.titles())
      assert Enum.sort(Enum.map(items, & &1.tmdb_id)) == Stub.movie_ids() ++ Stub.show_ids()

      for item <- items do
        assert item.metadata.poster_path =~ ~r{^/demo-.*-poster\.jpg$}
        assert item.metadata.backdrop_path =~ ~r{^/demo-.*-backdrop\.jpg$}
      end

      # Every season of the stub catalog: 6 + 5 for the first show, 5 for the second.
      assert episodes == 16
      assert episodes == Repo.aggregate(Episode, :count)
      refute Repo.exists?(from e in Episode, where: e.season_number == 0)
    end

    test "items and episodes are unmonitored", ctx do
      {:ok, _} = seed(ctx)

      assert Repo.all(from i in MediaItem, select: i.monitored) |> Enum.uniq() == [false]
      assert Repo.all(from e in Episode, select: e.monitored) |> Enum.uniq() == [false]
    end

    test "refuses a database that already holds media and writes nothing", ctx do
      insert(:media_item)

      assert {:error, :not_empty} = seed(ctx)
      assert {1, 0, 0, 0} = counts()
    end

    test "a failed fetch writes nothing", ctx do
      titles = write_titles(ctx.tmp_dir, catalog_lines() ++ ["movie #{Stub.missing_id()}"])
      missing = {:movie, Stub.missing_id()}

      assert {:error, {:fetch_failed, ^missing, _reason}} = seed(%{ctx | titles: titles})
      assert {0, 0, 0, 0} = counts()
    end

    test "reuses demo library paths left over from an earlier run", ctx do
      {:ok, _} = LibraryPaths.create_library_path(%{path: "/demo/movies", type: :movies})

      assert {:ok, %{movies: 3}} = seed(ctx)
      assert Repo.aggregate(from(l in LibraryPath, where: l.path == "/demo/movies"), :count) == 1
    end

    test "refuses a demo library path of the wrong type and writes nothing", ctx do
      {:ok, _} = LibraryPaths.create_library_path(%{path: "/demo/tv", type: :movies})

      assert {:error, {:library_path_conflict, "/demo/tv", :movies}} = seed(ctx)
      assert {0, 0, 0, 0} = counts()
    end

    test "a missing title list is reported", ctx do
      path = Path.join(ctx.tmp_dir, "absent.local")
      assert {:error, {:titles_file, ^path, :enoent}} = seed(%{ctx | titles: path})
    end

    test "movies get one file; TV files hang off aired episodes only", ctx do
      {:ok, _} = seed(ctx)
      today = Date.utc_today()

      for movie <- Repo.all(from m in MediaItem, where: m.type == "movie") do
        assert Repo.aggregate(from(f in MediaFile, where: f.media_item_id == ^movie.id), :count) ==
                 1
      end

      episode_files =
        Repo.all(
          from f in MediaFile,
            join: e in Episode,
            on: e.id == f.episode_id,
            select: {f, e}
        )

      aired = Repo.aggregate(from(e in Episode, where: e.air_date <= ^today), :count)
      assert length(episode_files) == aired

      for {file, episode} <- episode_files do
        assert is_nil(file.media_item_id)
        assert Date.compare(episode.air_date, today) != :gt
      end
    end

    test "populates Continue Watching and the calendar", ctx do
      {:ok, _} = seed(ctx)

      in_progress =
        Repo.all(
          from p in Progress,
            where:
              p.user_id == ^ctx.user.id and p.position_seconds > 0 and
                p.position_seconds < p.duration_seconds
        )

      # Two movies and one episode in each of two shows.
      assert length(in_progress) == 4
      assert Enum.count(in_progress, &(not is_nil(&1.media_item_id))) == 2
      assert Enum.count(in_progress, &(not is_nil(&1.episode_id))) == 2

      watched =
        Repo.aggregate(
          from(p in Progress,
            where: p.user_id == ^ctx.user.id and p.position_seconds >= p.duration_seconds
          ),
          :count
        )

      assert watched > 0

      today = Date.utc_today()
      limit = Date.add(today, 14)

      upcoming =
        Repo.aggregate(
          from(e in Episode, where: e.air_date > ^today and e.air_date <= ^limit),
          :count
        )

      assert upcoming == Stub.upcoming_count()
    end
  end
end
