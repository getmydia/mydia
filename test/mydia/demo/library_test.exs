defmodule Mydia.Demo.LibraryTest do
  use Mydia.DataCase, async: false

  alias Mydia.Demo.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.Progress

  @base_url "http://demo.test"

  defp opts(ctx) do
    [art_source: ctx.art_source, art_dir: ctx.art_dir, base_url: @base_url, user: ctx.user]
  end

  describe "seed/1" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      art_dir = Path.join(tmp_dir, "art")
      art_source = Path.join(tmp_dir, "source")
      File.mkdir_p!(art_source)

      # Tiny stand-ins for the committed JPEGs, one pair per title.
      for title <- Library.titles(),
          file <- Tuple.to_list(Library.art_files(title)),
          do: File.write!(Path.join(art_source, file), "jpg:" <> file)

      user = insert(:user, role: "admin")

      {:ok, art_dir: art_dir, art_source: art_source, user: user}
    end

    test "seeds an empty database", ctx do
      assert {:ok, %{movies: m, shows: s, episodes: e}} = Library.seed(opts(ctx))
      assert m >= 18
      assert s >= 6
      assert e > 0

      titles = Library.titles()
      items = Repo.all(MediaItem)
      assert length(items) == m + s
      assert Enum.all?(items, &(&1.title in titles))
      assert Enum.all?(items, &(&1.tmdb_id >= 2_000_000_000))
      assert Enum.all?(items, &(&1.monitored == false))

      movies = Enum.filter(items, &(&1.type == "movie"))
      assert length(movies) == m

      for item <- items do
        {poster_file, backdrop_file} = Library.art_files(item.title)

        for {url, file} <- [
              {item.metadata.poster_path, poster_file},
              {item.metadata.backdrop_path, backdrop_file}
            ] do
          assert url == @base_url <> "/images/demo/" <> file
          assert File.read!(Path.join(ctx.art_dir, file)) == "jpg:" <> file
        end
      end
    end

    test "art file names follow the slug rule" do
      assert Library.art_files("Fennick's Wager") ==
               {"fennick-s-wager-poster.jpg", "fennick-s-wager-backdrop.jpg"}
    end

    test "the committed art covers every title" do
      source = Path.expand("assets/demo/art", File.cwd!())

      for title <- Library.titles(), file <- Tuple.to_list(Library.art_files(title)) do
        assert File.regular?(Path.join(source, file)), "missing #{file}"
      end
    end

    test "refuses a database that already holds media", ctx do
      insert(:media_item)

      assert {:error, :not_empty} = Library.seed(opts(ctx))
      assert Repo.aggregate(MediaItem, :count) == 1
      assert File.ls(ctx.art_dir) in [{:error, :enoent}, {:ok, []}]
    end

    test "fails before writing when art is missing", ctx do
      [title | _] = Library.titles()
      {_poster, backdrop} = Library.art_files(title)
      File.rm!(Path.join(ctx.art_source, backdrop))

      assert {:error, {:art_missing, [^backdrop]}} = Library.seed(opts(ctx))
      assert Repo.aggregate(MediaItem, :count) == 0
      assert Repo.aggregate(MediaFile, :count) == 0
      assert Repo.aggregate(Episode, :count) == 0
      assert File.ls(ctx.art_dir) in [{:error, :enoent}, {:ok, []}]
    end

    test "episode files hang off episodes", ctx do
      {:ok, _} = Library.seed(opts(ctx))

      episode_files = Repo.all(from f in MediaFile, where: not is_nil(f.episode_id))
      assert episode_files != []
      assert Enum.all?(episode_files, &is_nil(&1.media_item_id))

      movies = Repo.all(from m in MediaItem, where: m.type == "movie")

      for movie <- movies do
        assert Repo.aggregate(from(f in MediaFile, where: f.media_item_id == ^movie.id), :count) ==
                 1
      end
    end

    test "episode titles are whole phrases", ctx do
      {:ok, _} = Library.seed(opts(ctx))

      titles = Repo.all(from e in Episode, select: e.title)
      assert Enum.any?(titles, &String.contains?(&1, " "))
      refute "Way" in titles
      refute "The" in titles
    end

    test "populates Continue Watching and the calendar", ctx do
      {:ok, _} = Library.seed(opts(ctx))

      in_progress =
        Repo.all(
          from p in Progress,
            where:
              p.user_id == ^ctx.user.id and p.position_seconds > 0 and
                p.position_seconds < p.duration_seconds
        )

      assert length(in_progress) >= 3

      today = Date.utc_today()
      limit = Date.add(today, 14)

      upcoming =
        Repo.aggregate(
          from(e in Episode, where: e.air_date >= ^today and e.air_date <= ^limit),
          :count
        )

      assert upcoming >= 3
    end
  end

  describe "titles/0" do
    test "titles are unique and fit a poster" do
      titles = Library.titles()
      assert titles == Enum.uniq(titles)
      assert Enum.all?(titles, &(String.length(&1) <= 40))
    end
  end
end
