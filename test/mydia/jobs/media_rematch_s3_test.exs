defmodule Mydia.Jobs.MediaRematchS3Test do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :s3

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Jobs.MediaRematch
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.S3Helpers
  alias Mydia.Storage

  @old_relative_path "Wrong Movie (2020)/movie.mkv"

  setup do
    File.rm_rf!("s3:")

    {library_path, loc} = S3Helpers.library_path!("movies")
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)

    old_movie = media_item_fixture(%{type: "movie", title: "Wrong Movie", year: 2020})
    new_movie = media_item_fixture(%{type: "movie", title: "Right Movie", year: 2021})

    body = "video-bytes"
    :ok = S3Helpers.put_object!(loc, @old_relative_path, body)

    download =
      download_fixture(%{
        media_item_id: new_movie.id,
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, media_file} =
      Library.create_media_file(%{
        relative_path: @old_relative_path,
        library_path_id: library_path.id,
        media_item_id: old_movie.id,
        size: byte_size(body),
        metadata: %{"imported_from_download_id" => download.id}
      })

    %{
      loc: loc,
      new_item: new_movie,
      media_file: media_file,
      old_relative_path: @old_relative_path,
      job_args: %{"download_id" => download.id}
    }
  end

  test "a rematched S3 file moves to the new item's key", ctx do
    assert {:ok, :rematched} = perform_job(MediaRematch, ctx.job_args)

    reloaded = Repo.get!(MediaFile, ctx.media_file.id)
    assert reloaded.media_item_id == ctx.new_item.id
    assert reloaded.relative_path != ctx.old_relative_path

    {:ok, new} = Storage.source(ctx.loc, reloaded.relative_path)
    {:ok, old} = Storage.source(ctx.loc, ctx.old_relative_path)
    assert Storage.exists?(new)
    refute Storage.exists?(old)
  end
end
