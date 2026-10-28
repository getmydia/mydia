defmodule Mydia.Library.LibraryMoveEnqueueTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :tmp_dir

  alias Mydia.Accounts.Scope
  alias Mydia.Library.LibraryMove
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  defp library(tmp, name, type, attrs \\ %{}) do
    path = Path.join(tmp, name)
    File.mkdir_p!(path)

    library_path_fixture(
      Map.merge(%{type: type, path: path, auto_organize: false, auto_rename: false}, attrs)
    )
  end

  defp put_file(library, rel, attrs) do
    abs = Path.join(library.path, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, "xyz")

    media_file_fixture(
      Map.merge(%{library_path_id: library.id, relative_path: rel, size: 3}, attrs)
    )
  end

  defp movie_in(lib) do
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    put_file(lib, "Glass Harbor (2019)/glass.mkv", %{media_item_id: movie.id})
    movie
  end

  setup %{tmp_dir: tmp} do
    %{a: library(tmp, "a", "movies"), b: library(tmp, "b", "movies"), scope: Scope.system()}
  end

  test "retargets the item and enqueues the job", %{a: a, b: b, scope: scope} do
    movie = movie_in(a)

    assert {:ok, %Oban.Job{}} = LibraryMove.enqueue(movie, b, scope)
    assert Repo.get!(MediaItem, movie.id).library_path_id == b.id

    assert_enqueued(
      worker: Mydia.Jobs.LibraryMove,
      args: %{"media_item_id" => movie.id, "target_library_path_id" => b.id, "actor_id" => nil}
    )
  end

  test "refuses a library of the wrong type", %{a: a, scope: scope, tmp_dir: tmp} do
    movie = movie_in(a)
    series = library(tmp, "s", "series")

    assert {:error, :incompatible_library} = LibraryMove.enqueue(movie, series, scope)
    refute_enqueued(worker: Mydia.Jobs.LibraryMove)
    assert Repo.get!(MediaItem, movie.id).library_path_id == nil
  end

  test "refuses a disabled library", %{a: a, scope: scope, tmp_dir: tmp} do
    movie = movie_in(a)
    disabled = library(tmp, "d", "movies", %{disabled: true})

    assert {:error, :disabled_library} = LibraryMove.enqueue(movie, disabled, scope)
  end

  test "refuses when every file is already there", %{b: b, scope: scope} do
    movie = movie_in(b)
    assert {:error, :already_there} = LibraryMove.enqueue(movie, b, scope)
  end

  test "refuses while an import for the item is pending", %{a: a, b: b, scope: scope} do
    movie = movie_in(a)
    download = Mydia.DownloadsFixtures.download_fixture(%{media_item_id: movie.id})
    Repo.insert!(Mydia.Jobs.MediaImport.new(%{"download_id" => download.id}))

    assert {:error, :import_in_progress} = LibraryMove.enqueue(movie, b, scope)
  end

  test "compatible_targets keeps only libraries every item fits", %{tmp_dir: tmp, a: a} do
    mixed = library(tmp, "m", "mixed")
    _series = library(tmp, "s", "series")
    off = library(tmp, "off", "mixed", %{disabled: true})
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2019})
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})

    ids = Enum.map(LibraryMove.compatible_targets([movie, show]), & &1.id)
    assert mixed.id in ids
    refute a.id in ids
    refute off.id in ids
    assert Enum.all?(LibraryMove.compatible_targets([movie, show]), &(&1.type == :mixed))
  end

  test "enqueue_many counts successes and reports failures", ctx do
    %{a: a, b: b, scope: scope} = ctx
    movie = movie_in(a)
    show = media_item_fixture(%{type: "tv_show", title: "The Quiet Meridian"})

    assert {1, [{failed, :incompatible_library}]} =
             LibraryMove.enqueue_many([movie, show], b, scope)

    assert failed.id == show.id
  end

  test "preview counts files, bytes and actions", %{a: a, b: b} do
    movie = movie_in(a)

    assert %{files: 1, bytes: 3, hardlink: 1, copy: 0, examples: [{src, dest}]} =
             LibraryMove.preview(movie, b)

    assert src == "Glass Harbor (2019)/glass.mkv"
    assert dest == "Glass Harbor (2019)/glass.mkv"
  end

  test "event_attrs describe a partial move", %{a: a, b: b} do
    movie = movie_in(a)
    attrs = LibraryMove.event_attrs(movie, b, [:moved, :skipped_conflict], "user-1")

    assert attrs.type == "media_item.library_moved"
    assert attrs.severity == :warning
    assert attrs.actor_type == :user
    assert attrs.metadata["moved"] == 1
    assert attrs.metadata["skipped"] == 1

    none = LibraryMove.event_attrs(movie, b, [:skipped_conflict], nil)
    assert none.type == "media_item.library_move_failed"
    assert none.actor_type == :system
    assert none.actor_id
  end
end
