defmodule Mydia.Jobs.LibraryMoveTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :tmp_dir

  alias Mydia.Accounts.Scope
  alias Mydia.Library.LibraryMove
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Subtitle

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp library(tmp, name, type) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)
    library_path_fixture(%{type: type, path: path, auto_organize: false, auto_rename: false})
  end

  defp write(path, body \\ "xyz") do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp put_file(library, rel, attrs) do
    write(Path.join(library.path, rel))

    media_file_fixture(
      Map.merge(%{library_path_id: library.id, relative_path: rel, size: 3}, attrs)
    )
  end

  defp insert_subtitle(file, path) do
    %Subtitle{}
    |> Subtitle.changeset(%{
      media_file_id: file.id,
      language: "en",
      provider: "test",
      subtitle_hash: "h1",
      file_path: path,
      format: "srt"
    })
    |> Repo.insert!()
  end

  defp run(item, target) do
    assert {:ok, job} = LibraryMove.enqueue(item, target, Scope.system())
    perform_job(Mydia.Jobs.LibraryMove, job.args)
  end

  setup %{tmp_dir: tmp} do
    a = library(tmp, "a", "movies")
    b = library(tmp, "b", "movies")
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    %{a: a, b: b, movie: movie}
  end

  test "moves the video, its sidecars and subtitle rows", %{a: a, b: b, movie: movie} do
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    srt = write(Path.join(a.path, "Glass Harbor (2019)/glass.en.srt"))
    nfo = write(Path.join(a.path, "Glass Harbor (2019)/glass.nfo"))

    subtitle = insert_subtitle(file, srt)

    assert :ok = run(movie, b)

    dest_dir = Path.join(b.path, "Glass Harbor (2019)")
    assert File.exists?(Path.join(dest_dir, "glass.mkv"))
    assert File.exists?(Path.join(dest_dir, "glass.en.srt"))
    assert File.exists?(Path.join(dest_dir, "glass.nfo"))
    refute File.exists?(srt)
    refute File.exists?(nfo)
    refute File.exists?(Path.join(a.path, "Glass Harbor (2019)"))

    moved = Repo.get!(MediaFile, file.id)
    assert moved.library_path_id == b.id
    assert moved.relative_path == "Glass Harbor (2019)/glass.mkv"
    assert Repo.get!(Subtitle, subtitle.id).file_path == Path.join(dest_dir, "glass.en.srt")
  end

  test "keeps a source folder that holds another item's file", ctx do
    %{a: a, b: b, movie: movie} = ctx
    put_file(a, "Shared/glass.mkv", %{media_item_id: movie.id})
    other = media_item_fixture(%{type: "movie", title: "Copper Lantern", year: 2020})
    put_file(a, "Shared/copper.mkv", %{media_item_id: other.id})
    poster = write(Path.join(a.path, "Shared/poster.jpg"))

    assert :ok = run(movie, b)

    assert File.exists?(Path.join(a.path, "Shared/copper.mkv"))
    assert File.exists?(poster)
    refute File.exists?(Path.join(a.path, "Shared/glass.mkv"))
  end

  test "carries artwork and Subs/ along and removes the emptied folder", ctx do
    %{a: a, b: b, movie: movie} = ctx
    put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    write(Path.join(a.path, "Glass Harbor (2019)/poster.jpg"))
    write(Path.join(a.path, "Glass Harbor (2019)/Subs/eng.srt"))

    assert :ok = run(movie, b)

    dest_dir = Path.join(b.path, "Glass Harbor (2019)")
    assert File.exists?(Path.join(dest_dir, "poster.jpg"))
    assert File.exists?(Path.join(dest_dir, "Subs/eng.srt"))
    refute File.exists?(Path.join(a.path, "Glass Harbor (2019)"))
    assert File.dir?(a.path)
  end

  test "a sidecar that cannot move stays at the source with its row", ctx do
    %{a: a, b: b, movie: movie} = ctx
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    srt = write(Path.join(a.path, "Glass Harbor (2019)/glass.en.srt"))
    write(Path.join(b.path, "Glass Harbor (2019)/glass.en.srt"), "someone else's")
    subtitle = insert_subtitle(file, srt)

    assert :ok = run(movie, b)

    assert File.exists?(srt)
    assert Repo.get!(Subtitle, subtitle.id).file_path == srt
    assert File.read!(Path.join(b.path, "Glass Harbor (2019)/glass.en.srt")) == "someone else's"
    assert File.dir?(Path.join(a.path, "Glass Harbor (2019)"))
  end

  test "a retry deletes a source whose relink already committed", ctx do
    %{a: a, b: b, movie: movie} = ctx
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    source = Path.join(a.path, file.relative_path)
    assert {:ok, job} = LibraryMove.enqueue(movie, b, Scope.system())

    # The first attempt placed and relinked, then died before deleting.
    dest = Path.join(b.path, "Glass Harbor (2019)/glass.mkv")
    File.mkdir_p!(Path.dirname(dest))
    File.ln!(source, dest)
    Repo.update!(Ecto.Changeset.change(file, library_path_id: b.id))

    assert :ok = perform_job(Mydia.Jobs.LibraryMove, job.args, attempt: 2)

    refute File.exists?(source)
    assert File.exists?(dest)
    refute File.exists?(Path.join(a.path, "Glass Harbor (2019)"))
  end

  test "the last attempt's event counts every file, not just its own", %{tmp_dir: tmp} do
    a = library(tmp, "sa", "series")
    b = library(tmp, "sb", "series")
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})
    e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    e2 = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 4})
    # Moved by an earlier attempt.
    put_file(b, "The Quiet Meridian/Season 01/qm.s01e01.mkv", %{episode_id: e1.id})
    put_file(a, "Meridian/qm.s02e04.mkv", %{episode_id: e2.id})
    assert {:ok, job} = LibraryMove.enqueue(show, b, Scope.system())
    # A file where the season folder should be: placing fails, not a conflict.
    write(Path.join(b.path, "The Quiet Meridian/Season 02"))

    assert {:error, {:transient, 1}} =
             perform_job(Mydia.Jobs.LibraryMove, job.args, attempt: 5)

    attrs = LibraryMove.event_attrs(show, b, nil)
    assert attrs.type == "media_item.library_moved"
    assert {attrs.metadata["moved"], attrs.metadata["skipped"]} == {1, 1}
    assert File.exists?(Path.join(a.path, "Meridian/qm.s02e04.mkv"))
  end

  # A crash between place and relink leaves the copy and the source. The
  # source is only deleted after the relink commits, so "copy present, source
  # gone, row unmoved" cannot come out of this job, and FileMove refuses to
  # adopt an unclaimed file without a source to compare it with.
  test "a retry adopts a destination copied before a crash", %{a: a, b: b, movie: movie} do
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    source = Path.join(a.path, file.relative_path)
    dest = Path.join(b.path, "Glass Harbor (2019)/glass.mkv")
    File.mkdir_p!(Path.dirname(dest))
    File.cp!(source, dest)

    assert :ok = run(movie, b)

    moved = Repo.get!(MediaFile, file.id)
    assert moved.library_path_id == b.id
    assert File.exists?(dest)
    refute File.exists?(source)
  end

  test "an untracked file at the destination is a conflict", %{a: a, b: b, movie: movie} do
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    write(Path.join(b.path, "Glass Harbor (2019)/glass.mkv"), "somebody else's")

    assert :ok = run(movie, b)

    assert File.exists?(Path.join(a.path, file.relative_path))
    assert Repo.get!(MediaFile, file.id).library_path_id == a.id
  end

  test "moves episodes into their season folders", %{tmp_dir: tmp} do
    a = library(tmp, "sa", "series")
    b = library(tmp, "sb", "series")
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})
    e1 = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    e2 = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 4})
    put_file(a, "Meridian/qm.s01e01.mkv", %{episode_id: e1.id})
    put_file(a, "Meridian/qm.s02e04.mkv", %{episode_id: e2.id})

    assert :ok = run(show, b)

    assert File.exists?(Path.join(b.path, "The Quiet Meridian/Season 01/qm.s01e01.mkv"))
    assert File.exists?(Path.join(b.path, "The Quiet Meridian/Season 02/qm.s02e04.mkv"))
  end

  test "cancels when the target was disabled after enqueue", %{a: a, b: b, movie: movie} do
    file = put_file(a, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    movie = Repo.update!(Ecto.Changeset.change(movie, library_path_id: a.id))
    assert {:ok, job} = LibraryMove.enqueue(movie, b, Scope.system())
    assert Repo.get!(MediaItem, movie.id).library_path_id == b.id
    Repo.update!(Ecto.Changeset.change(Repo.get!(LibraryPath, b.id), disabled: true))

    assert {:cancel, :target_unavailable} = perform_job(Mydia.Jobs.LibraryMove, job.args)
    assert File.exists?(Path.join(a.path, file.relative_path))
    refute File.exists?(Path.join(b.path, "Glass Harbor (2019)"))
    assert Repo.get!(MediaItem, movie.id).library_path_id == a.id
  end

  test "a missing item is a no-op", %{b: b} do
    args = %{
      "media_item_id" => Ecto.UUID.generate(),
      "target_library_path_id" => b.id,
      "actor_id" => nil
    }

    assert :ok = perform_job(Mydia.Jobs.LibraryMove, args)
  end
end
