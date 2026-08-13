defmodule Mydia.Downloads.ByteSizeOverflowTest do
  @moduledoc """
  Regression tests for issue #278.

  `transcode_jobs.file_size` and `downloads.last_known_bytes` were declared
  `:integer`, which PostgreSQL realises as int4 (max 2,147,483,647). Both hold
  byte counts, so any media file over ~2.1 GB crashed the write with
  `DBConnection.EncodeError` from `Postgrex.DefaultTypes.encode_params/3`.

  Both values below are taken verbatim from the production crash report.

  These tests pass trivially on SQLite, whose INTEGER storage class is already
  64-bit, so they are only meaningful on PostgreSQL. See
  `Mydia.Repo.ByteColumnTypesTest` for the guard that stops a new int4 byte
  column from being added in the first place.
  """
  use Mydia.DataCase

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Transcoding

  # Observed in the crash report on issue #278: ~8.3 GB and ~7.5 GB.
  @over_int4_bytes 8_324_361_099
  @over_int4_file_size 7_565_057_364

  describe "byte-size columns above the int4 ceiling" do
    test "downloads.last_known_bytes round-trips a value over 2.1 GB" do
      download = download_fixture(%{last_known_bytes: @over_int4_bytes})

      assert Downloads.get_download!(download.id).last_known_bytes == @over_int4_bytes
    end

    test "transcode_jobs.file_size round-trips a value over 2.1 GB" do
      library = insert(:library_path, type: :movies)
      media_item = insert(:media_item, type: "movie")

      media_file =
        insert(:media_file,
          media_item: media_item,
          library_path: library,
          relative_path: "big-movie.mkv",
          size: @over_int4_file_size
        )

      {:ok, job} = Transcoding.get_or_create_job(media_file.id, "1080p")

      assert {:ok, completed} =
               Transcoding.complete_job(job, "/transcodes/big-movie.mp4", @over_int4_file_size)

      assert completed.file_size == @over_int4_file_size
    end
  end
end
