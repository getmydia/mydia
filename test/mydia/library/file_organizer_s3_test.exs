defmodule Mydia.Library.FileOrganizerS3Test do
  use Mydia.DataCase, async: false

  @moduletag :s3

  alias Mydia.Library.{FileOrganizer, MediaFile}
  alias Mydia.Media.MediaItem
  alias Mydia.S3Helpers
  alias Mydia.Storage

  setup do
    {lp, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)

    # The changeset still rejects auto_organize on S3 libraries, so set it directly.
    lp = lp |> Ecto.Changeset.change(auto_organize: true) |> Repo.update!()

    S3Helpers.put_object!(loc, "loose/film.mkv", "bytes")

    {:ok, media_item} =
      %MediaItem{}
      |> MediaItem.changeset(%{title: "Invented Film", year: 2031, type: "movie"})
      |> Repo.insert()

    {:ok, file} =
      %MediaFile{}
      |> MediaFile.scan_changeset(%{
        relative_path: "loose/film.mkv",
        library_path_id: lp.id,
        media_item_id: media_item.id
      })
      |> Repo.insert()

    %{lp: lp, loc: loc, mf: file}
  end

  test "organize_file moves the object to the organized location", ctx do
    assert {:ok, %{action: :move, destination: dest}} = FileOrganizer.organize_file(ctx.mf)
    assert String.starts_with?(dest, ctx.lp.path <> "/Invented Film (2031)")

    reloaded = Repo.get!(MediaFile, ctx.mf.id)
    {:ok, moved} = Storage.source(ctx.loc, reloaded.relative_path)
    {:ok, old} = Storage.source(ctx.loc, "loose/film.mkv")
    assert Storage.exists?(moved)
    refute Storage.exists?(old)
  end

  test "reorganize_library dry run lists the move without touching the bucket", ctx do
    assert {:ok, %{total: 1}} = FileOrganizer.reorganize_library(ctx.lp, dry_run: true)
    {:ok, old} = Storage.source(ctx.loc, "loose/film.mkv")
    assert Storage.exists?(old)
  end
end
