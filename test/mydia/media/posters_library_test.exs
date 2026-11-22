defmodule Mydia.Media.PostersLibraryTest do
  # Changes the global :generated_media_path env, so it cannot run async.
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media.PosterStore
  alias Mydia.Media.Posters
  alias Mydia.S3Helpers

  @jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0::64>>

  setup do
    base = Path.join(System.tmp_dir!(), "posters_lib_#{System.unique_integer([:positive])}")
    store = Path.join(base, "store")
    root = Path.join(base, "library")
    File.mkdir_p!(store)
    File.mkdir_p!(root)

    previous = Application.fetch_env(:mydia, :generated_media_path)
    Application.put_env(:mydia, :generated_media_path, store)
    File.mkdir_p!(PosterStore.storage_dir())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :generated_media_path, value)
        :error -> Application.delete_env(:mydia, :generated_media_path)
      end

      File.rm_rf!(base)
    end)

    %{root: root}
  end

  defp write!(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp movie_setup(root) do
    movie_dir = "Some Film (2001)"
    write!(root, "#{movie_dir}/film.mkv", "video")
    write!(root, "#{movie_dir}/poster.jpg", @jpg)
    write!(root, "#{movie_dir}/fanart.png", @png)
    write!(root, "#{movie_dir}/notes.txt", "hello")
    File.ln_s!("/etc/hostname", Path.join([root, movie_dir, "link.jpg"]))

    lp = library_path_fixture(%{path: root, type: "movies"})
    item = media_item_fixture(%{type: "movie"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "#{movie_dir}/film.mkv"
    })

    {item, lp}
  end

  describe "local library" do
    test "movie: image files in the media file's folder, poster/folder/cover first, no symlinks or non-images",
         %{root: root} do
      {item, lp} = movie_setup(root)
      candidates = Posters.list_library_poster_candidates(item)

      assert Enum.map(candidates, & &1.name) == ["poster.jpg", "fanart.png"]

      assert [%Posters.Candidate{library_path_id: lp_id, relative_path: rel, size: size} | _] =
               candidates

      assert lp_id == lp.id
      assert rel == "Some Film (2001)/poster.jpg"
      assert size == byte_size(@jpg)
    end

    test "tv show: images at the show root, not inside season folders", %{root: root} do
      write!(root, "Show Name/Season 01/e01.mkv", "video")
      write!(root, "Show Name/poster.png", @png)
      write!(root, "Show Name/Season 01/season01-poster.jpg", @jpg)

      lp = library_path_fixture(%{path: root, type: "series"})
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      media_file_fixture(%{
        episode_id: episode.id,
        library_path_id: lp.id,
        relative_path: "Show Name/Season 01/e01.mkv"
      })

      assert show |> Posters.list_library_poster_candidates() |> Enum.map(& &1.name) ==
               ["poster.png"]
    end

    test "tv show: Season NN, SNN and Specials folders all walk up to the show root",
         %{root: root} do
      write!(root, "Show Name/Season 01/e01.mkv", "video")
      write!(root, "Show Name/S02/e01.mkv", "video")
      write!(root, "Show Name/Specials/e00.mkv", "video")
      write!(root, "Show Name/poster.png", @png)
      write!(root, "Show Name/S02/s02.jpg", @jpg)
      write!(root, "Show Name/Specials/specials.jpg", @jpg)

      lp = library_path_fixture(%{path: root, type: "series"})
      show = media_item_fixture(%{type: "tv_show"})

      for {rel, n} <- Enum.with_index(["Season 01/e01.mkv", "S02/e01.mkv", "Specials/e00.mkv"], 1) do
        episode = episode_fixture(%{media_item_id: show.id, episode_number: n})

        media_file_fixture(%{
          episode_id: episode.id,
          library_path_id: lp.id,
          relative_path: "Show Name/#{rel}"
        })
      end

      assert show |> Posters.list_library_poster_candidates() |> Enum.map(& &1.name) ==
               ["poster.png"]
    end

    test "tv show: a show folder whose name starts like a season folder is not walked up",
         %{root: root} do
      write!(root, "Series Of Odd Events/e01.mkv", "video")
      write!(root, "Series Of Odd Events/poster.jpg", @jpg)

      lp = library_path_fixture(%{path: root, type: "series"})
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      media_file_fixture(%{
        episode_id: episode.id,
        library_path_id: lp.id,
        relative_path: "Series Of Odd Events/e01.mkv"
      })

      assert show |> Posters.list_library_poster_candidates() |> Enum.map(& &1.name) ==
               ["poster.jpg"]
    end

    test "a trashed file's folder offers no candidates", %{root: root} do
      write!(root, "Old Copy (2001)/film.mkv", "video")
      write!(root, "Old Copy (2001)/poster.jpg", @jpg)
      lp = library_path_fixture(%{path: root, type: "movies"})
      item = media_item_fixture(%{type: "movie"})

      file =
        media_file_fixture(%{
          media_item_id: item.id,
          library_path_id: lp.id,
          relative_path: "Old Copy (2001)/film.mkv"
        })

      file
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now(:second))
      |> Mydia.Repo.update!()

      assert Posters.list_library_poster_candidates(item) == []
    end

    test "a movie file directly in the library root lists nothing", %{root: root} do
      write!(root, "loose.mkv", "video")
      write!(root, "someone-elses.jpg", @jpg)
      lp = library_path_fixture(%{path: root, type: "movies"})
      item = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: item.id,
        library_path_id: lp.id,
        relative_path: "loose.mkv"
      })

      assert Posters.list_library_poster_candidates(item) == []
    end

    test "an item without files has no candidates" do
      assert media_item_fixture(%{type: "movie"}) |> Posters.list_library_poster_candidates() ==
               []
    end

    test "selecting a candidate copies it into the poster store", %{root: root} do
      {item, _lp} = movie_setup(root)
      [c | _] = Posters.list_library_poster_candidates(item)

      assert {:ok, item} =
               Posters.set_poster_from_library_file(
                 Scope.unrestricted(),
                 item,
                 c.library_path_id,
                 c.relative_path
               )

      assert PosterStore.hosted?(item.poster_override)

      assert File.exists?(
               Path.join(PosterStore.storage_dir(), Path.basename(item.poster_override))
             )
    end

    test "read_candidate returns the bytes of a listed candidate", %{root: root} do
      {item, lp} = movie_setup(root)
      assert {:ok, @jpg} = Posters.read_candidate(item, lp.id, "Some Film (2001)/poster.jpg")
    end

    test "a path that is not a listed candidate is refused", %{root: root} do
      {item, lp} = movie_setup(root)

      for rel <- [
            "../../etc/hostname",
            "/etc/hostname",
            "Some Film (2001)/link.jpg",
            "Some Film (2001)/notes.txt"
          ] do
        assert {:error, :not_found} =
                 Posters.set_poster_from_library_file(Scope.unrestricted(), item, lp.id, rel)

        assert {:error, :not_found} = Posters.read_candidate(item, lp.id, rel)
      end

      assert {:error, :not_found} =
               Posters.read_candidate(item, Ecto.UUID.generate(), "Some Film (2001)/poster.jpg")
    end

    test "a candidate over the size limit is :too_large", %{root: root} do
      {item, lp} = movie_setup(root)
      write!(root, "Some Film (2001)/huge.jpg", @jpg)
      {:ok, fd} = File.open(Path.join(root, "Some Film (2001)/huge.jpg"), [:write, :binary])
      {:ok, _} = :file.position(fd, 10_000_001)
      :ok = IO.binwrite(fd, <<0>>)
      File.close(fd)

      assert {:error, :too_large} =
               Posters.read_candidate(item, lp.id, "Some Film (2001)/huge.jpg")
    end
  end

  @tag :s3
  test "an S3 library's poster is listed and copied" do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    S3Helpers.put_object!(loc, "Some Film (2001)/film.mkv", "video")
    S3Helpers.put_object!(loc, "Some Film (2001)/poster.jpg", @jpg)
    S3Helpers.put_object!(loc, "Some Film (2001)/extras/other.jpg", @jpg)

    item = media_item_fixture(%{type: "movie"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "Some Film (2001)/film.mkv"
    })

    assert [%{name: "poster.jpg"} = c] = Posters.list_library_poster_candidates(item)

    assert {:ok, updated} =
             Posters.set_poster_from_library_file(
               Scope.unrestricted(),
               item,
               c.library_path_id,
               c.relative_path
             )

    assert PosterStore.hosted?(updated.poster_override)
  end
end
