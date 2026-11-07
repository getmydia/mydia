defmodule Mydia.Demo.LibraryTest do
  use Mydia.DataCase, async: false

  alias Mydia.Demo.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Playback.Progress

  @base_url "http://demo.test"

  # A 1x1 PNG, so the suite does not need librsvg.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

  defp opts(ctx) do
    [art_dir: ctx.art_dir, renderer: ctx.renderer, base_url: @base_url, user: ctx.user]
  end

  describe "seed/1" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      art_dir = Path.join(tmp_dir, "art")
      renderer = Path.join(tmp_dir, "fake-rsvg")

      File.write!(renderer, """
      #!/bin/sh
      out=""
      while [ $# -gt 0 ]; do
        if [ "$1" = "-o" ]; then out="$2"; fi
        shift
      done
      printf '%s' '#{@png_b64}' | base64 -d > "$out"
      """)

      File.chmod!(renderer, 0o755)

      user = insert(:user, role: "admin")

      {:ok, art_dir: art_dir, renderer: renderer, user: user}
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

      movies = Enum.filter(items, &(&1.type == "movie"))
      assert length(movies) == m

      for movie <- movies do
        poster = movie.metadata.poster_path
        assert String.starts_with?(poster, @base_url <> "/images/demo/")
        assert File.exists?(Path.join(ctx.art_dir, Path.basename(poster)))
      end
    end

    test "refuses a database that already holds media", ctx do
      insert(:media_item)

      assert {:error, :not_empty} = Library.seed(opts(ctx))
      assert Repo.aggregate(MediaItem, :count) == 1
      assert File.ls(ctx.art_dir) in [{:error, :enoent}, {:ok, []}]
    end

    test "fails before writing when the renderer is missing", ctx do
      opts = Keyword.put(opts(ctx), :renderer, "/nonexistent/rsvg-convert")

      assert {:error, {:renderer_missing, _}} = Library.seed(opts)
      assert Repo.aggregate(MediaItem, :count) == 0
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
