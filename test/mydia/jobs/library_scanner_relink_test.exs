defmodule Mydia.Jobs.LibraryScannerRelinkTest do
  @moduledoc """
  A file renamed or moved outside Mydia keeps its `media_files` row across
  library scans: the row is repointed at the new path instead of being
  trashed while a fresh row is created for the same bytes.
  """
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.LibraryScanner
  alias Mydia.Library
  alias Mydia.Library.{FailingMatcher, MediaFile, MediaSegment}
  alias Mydia.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    a_dir = Path.join(tmp_dir, "a")
    b_dir = Path.join(tmp_dir, "b")
    File.mkdir_p!(a_dir)
    File.mkdir_p!(b_dir)

    a = library_path_fixture(%{path: a_dir, type: "movies", auto_import: true})
    b = library_path_fixture(%{path: b_dir, type: "movies", auto_import: true})
    item = media_item_fixture(%{type: "movie", title: "Quillbrook Harbour"})

    %{a: a, b: b, item: item}
  end

  defp scan(library_path) do
    assert {:ok, %Library.ScanSummary{}} =
             LibraryScanner.scan_library_path(library_path, matcher: FailingMatcher)
  end

  defp owned_file(library_path, item, relative_path, content \\ "quillbrook-bytes") do
    absolute = Path.join(library_path.path, relative_path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)

    {:ok, media_file} =
      Library.create_media_file(%{
        media_item_id: item.id,
        library_path_id: library_path.id,
        relative_path: relative_path,
        size: byte_size(content),
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    media_file
  end

  defp move!(from_lp, from_rel, to_lp, to_rel) do
    to = Path.join(to_lp.path, to_rel)
    File.mkdir_p!(Path.dirname(to))
    File.rename!(Path.join(from_lp.path, from_rel), to)
  end

  defp rows_for(item) do
    Repo.all(from f in MediaFile, where: f.media_item_id == ^item.id)
  end

  test "a rename within a library keeps the row and what hangs off it", %{a: a, item: item} do
    row = owned_file(a, item, "Film (2001)/a.mkv")

    {:ok, segment} =
      %MediaSegment{}
      |> MediaSegment.changeset(%{
        media_file_id: row.id,
        type: "intro",
        start_ms: 0,
        end_ms: 1000,
        source: "chapters",
        confidence: 1.0
      })
      |> Repo.insert()

    move!(a, "Film (2001)/a.mkv", a, "Film (2001)/b.mkv")
    scan(a)

    assert [relinked] = rows_for(item)
    assert relinked.id == row.id
    assert relinked.relative_path == "Film (2001)/b.mkv"
    assert is_nil(relinked.trashed_at)
    assert Repo.get(MediaSegment, segment.id)
  end

  test "a move between libraries relinks when the old library is scanned first",
       %{a: a, b: b, item: item} do
    row = owned_file(a, item, "Film (2001)/f.mkv")
    move!(a, "Film (2001)/f.mkv", b, "Film (2001)/f.mkv")

    scan(a)
    assert %{trashed_reason: :missing} = Repo.get!(MediaFile, row.id)

    scan(b)

    assert [relinked] = rows_for(item)
    assert relinked.id == row.id
    assert relinked.library_path_id == b.id
    assert relinked.relative_path == "Film (2001)/f.mkv"
    assert is_nil(relinked.trashed_at)
  end

  test "a move between libraries relinks when the new library is scanned first",
       %{a: a, b: b, item: item} do
    row = owned_file(a, item, "Film (2001)/f.mkv")
    move!(a, "Film (2001)/f.mkv", b, "Film (2001)/f.mkv")

    scan(b)

    assert [relinked] = rows_for(item)
    assert relinked.id == row.id
    assert relinked.library_path_id == b.id
    assert is_nil(relinked.trashed_at)

    scan(a)

    assert [after_a] = rows_for(item)
    assert after_a.id == row.id
    assert after_a.library_path_id == b.id
    assert is_nil(after_a.trashed_at)
  end

  test "an active row in another library whose file is still there is never taken",
       %{a: a, b: b, item: item} do
    row = owned_file(a, item, "Film (2001)/f.mkv")
    File.mkdir_p!(Path.join(b.path, "Film (2001)"))
    File.cp!(Path.join(a.path, "Film (2001)/f.mkv"), Path.join(b.path, "Film (2001)/f.mkv"))

    scan(b)

    assert %{library_path_id: a_id, trashed_at: nil} = Repo.get!(MediaFile, row.id)
    assert a_id == a.id
  end

  test "an active row whose library root is gone is never taken", %{a: a, b: b, item: item} do
    row = owned_file(a, item, "Film (2001)/f.mkv")
    File.mkdir_p!(Path.join(b.path, "Film (2001)"))
    File.cp!(Path.join(a.path, "Film (2001)/f.mkv"), Path.join(b.path, "Film (2001)/f.mkv"))
    File.rm_rf!(a.path)

    scan(b)

    assert %{library_path_id: a_id, trashed_at: nil} = Repo.get!(MediaFile, row.id)
    assert a_id == a.id
  end

  test "a plain delete trashes the row as missing, off the trash page", %{a: a, item: item} do
    row = owned_file(a, item, "Film (2001)/a.mkv")
    File.rm!(Path.join(a.path, "Film (2001)/a.mkv"))

    scan(a)

    assert %{trashed_reason: :missing, trashed_at: %DateTime{}} = Repo.get!(MediaFile, row.id)
    refute Enum.any?(Library.list_trashed_media_files(), &(&1.id == row.id))
  end

  test "a file that reappears at the same path is restored", %{a: a, item: item} do
    row = owned_file(a, item, "Film (2001)/a.mkv")
    path = Path.join(a.path, "Film (2001)/a.mkv")
    File.rm!(path)

    scan(a)
    assert %{trashed_reason: :missing} = Repo.get!(MediaFile, row.id)

    File.write!(path, "quillbrook-bytes")
    scan(a)

    assert [restored] = rows_for(item)
    assert restored.id == row.id
    assert is_nil(restored.trashed_at)
  end

  test "a rename is relinked even when auto_import is off", %{item: item, tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "manual")
    File.mkdir_p!(dir)
    lp = library_path_fixture(%{path: dir, type: "movies", auto_import: false})
    row = owned_file(lp, item, "Film (2001)/a.mkv")

    move!(lp, "Film (2001)/a.mkv", lp, "Film (2001)/b.mkv")
    scan(lp)

    assert [relinked] = rows_for(item)
    assert relinked.id == row.id
    assert relinked.relative_path == "Film (2001)/b.mkv"
    assert is_nil(relinked.trashed_at)
  end
end
