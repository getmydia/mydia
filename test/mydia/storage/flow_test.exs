defmodule Mydia.Storage.FlowTest do
  @moduledoc """
  End to end read path for an S3 library against the devenv RustFS server:
  scan, analyze, stream over HTTP with a Range request, and deletion handling.
  """
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :s3
  @moduletag :ffmpeg
  @moduletag :tmp_dir

  import Ecto.Query
  import Mydia.MediaFixtures

  alias Mydia.Jobs.{FileAnalysis, LibraryScanner}
  alias Mydia.Library
  alias Mydia.S3Helpers
  alias Mydia.Settings

  @relative_path "Invented Film (2031)/Invented Film (2031).mp4"

  setup %{tmp_dir: tmp_dir} do
    {template, loc} = S3Helpers.s3_media_file!(relative_path: @relative_path, tmp_dir: tmp_dir)
    on_exit(fn -> S3Helpers.delete_prefix!(loc) end)

    {:ok, library_path} =
      Settings.create_library_path(%{
        path: String.trim_trailing(loc.uri, "/"),
        type: "movies",
        monitored: true
      })

    movie = media_item_fixture(%{type: "movie", title: "Invented Film", year: 2031})

    file =
      media_file_fixture(%{
        library_path_id: library_path.id,
        media_item_id: movie.id,
        relative_path: template.relative_path
      })

    # The fixture arrives pre-analyzed; clear it so the analysis job has work.
    Mydia.Repo.update_all(
      from(m in Library.MediaFile, where: m.id == ^file.id),
      set: [analyzed_at: nil, codec: nil, size: nil]
    )

    {_user, token} = MydiaWeb.AuthHelpers.create_user_and_token()
    %{library_path: library_path, media_file: file, loc: loc, token: token}
  end

  defp scan(library_path),
    do: perform_job(LibraryScanner, %{"library_path_id" => library_path.id})

  test "scan keeps the file, analysis fills metadata and a Range request streams it", ctx do
    assert :ok = scan(ctx.library_path)

    [row] = Library.list_media_files(library_path_id: ctx.library_path.id)
    assert row.relative_path == @relative_path
    assert row.trashed_at == nil

    assert :ok = perform_job(FileAnalysis, %{})
    analyzed = Library.get_media_file!(row.id)
    assert is_binary(analyzed.codec)
    assert analyzed.size > 0

    conn =
      ctx.conn
      |> put_req_header("authorization", "Bearer #{ctx.token}")
      |> put_req_header("range", "bytes=0-99")
      |> get("/api/v1/stream/file/#{row.id}")

    assert conn.status == 206
    assert byte_size(conn.resp_body) == 100
    assert [<<"bytes 0-99/", _::binary>>] = get_resp_header(conn, "content-range")
  end

  test "a deleted object is trashed, a credentials failure trashes nothing", ctx do
    backend_row = Settings.get_storage_backend_by_name(S3Helpers.backend().name)
    secret = S3Helpers.backend().secret_access_key

    {:ok, broken} =
      Settings.update_storage_backend(backend_row, %{secret_access_key: "wrong-secret"})

    assert {:error, _} = scan(ctx.library_path)
    assert Library.get_media_file!(ctx.media_file.id).trashed_at == nil

    {:ok, _} = Settings.update_storage_backend(broken, %{secret_access_key: secret})
    S3Helpers.delete_prefix!(ctx.loc)
    assert :ok = scan(ctx.library_path)
    assert Library.get_media_file!(ctx.media_file.id).trashed_at != nil
  end
end
