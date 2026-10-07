defmodule Mydia.Library.TrashStoreS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.{MediaFile, TrashStore}
  alias Mydia.S3Helpers
  alias Mydia.Storage

  @rel "Invented Film (2031)/film.mkv"

  setup do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)
    S3Helpers.put_object!(loc, @rel, "bytes")
    mf = media_file_fixture(%{library_path_id: lp.id, relative_path: @rel})
    %{lp: lp, loc: loc, mf: Repo.preload(Repo.get!(MediaFile, mf.id), :library_path)}
  end

  defp object(loc, rel) do
    {:ok, src} = Storage.source(loc, rel)
    src
  end

  test "trashing moves the object into the bucket's trash, out of every listing", ctx do
    assert {:ok, trashed} = Library.trash_media_file(ctx.mf, reason: :manual)
    assert trashed.trashed_at

    trash_path = trashed.metadata.extra["trashed_path"]
    assert trash_path == Path.join([ctx.lp.path, ".mydia-trash", ctx.mf.id, "film.mkv"])

    refute Storage.exists?(object(ctx.loc, @rel))
    assert Storage.path_exists?(trash_path)
    assert {:ok, []} = Storage.list(ctx.loc)
  end

  test "restore moves it back", ctx do
    {:ok, trashed} = Library.trash_media_file(ctx.mf, reason: :manual)
    assert {:ok, restored} = Library.restore_media_file(trashed)
    refute restored.trashed_at
    assert {:ok, "bytes"} = Storage.read(object(ctx.loc, @rel))
  end

  test "restore onto an occupied key keeps the trashed copy", ctx do
    {:ok, trashed} = Library.trash_media_file(ctx.mf, reason: :manual)
    S3Helpers.put_object!(ctx.loc, @rel, "newer")

    assert {:ok, _restored, :trash_copy_retained} = Library.restore_media_file(trashed)
    assert {:ok, "newer"} = Storage.read(object(ctx.loc, @rel))
    assert Storage.path_exists?(trashed.metadata.extra["trashed_path"])
  end

  test "purge deletes the trashed object", ctx do
    {:ok, trashed} = Library.trash_media_file(ctx.mf, reason: :manual)
    assert :ok = Library.purge_media_file(trashed)
    refute Storage.path_exists?(trashed.metadata.extra["trashed_path"])
  end

  test "store with move: false never moves a present object", ctx do
    assert {:error, :file_present} = TrashStore.store(ctx.mf, move: false)
    assert Storage.exists?(object(ctx.loc, @rel))
  end

  test "a missing object is recorded as missing", ctx do
    :ok = Storage.delete(object(ctx.loc, @rel))
    assert {:ok, :missing} = TrashStore.store(ctx.mf, move: false)
  end
end
