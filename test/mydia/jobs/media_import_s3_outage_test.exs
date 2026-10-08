defmodule Mydia.Jobs.MediaImportS3OutageTest do
  # A storage outage must never read as a free filename: the import fails
  # without uploading anything.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  @moduletag :tmp_dir

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Jobs.MediaImport
  alias Mydia.Settings

  @ideal "/lib/movies/Invented%20Film%20%282031%29/Invented%20Film%20%282031%29.mkv"
  @conflict "/lib/movies/Invented%20Film%20%282031%29/Invented%20Film%20%282031%29.1.mkv"

  setup %{tmp_dir: tmp_dir} do
    bypass = Bypass.open()

    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "outage#{System.unique_integer([:positive])}",
        endpoint: "http://localhost:#{bypass.port}",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s",
        path_style: true
      })

    backend = List.last(Settings.list_storage_backends())

    {:ok, library_path} =
      Settings.create_library_path(%{
        path: "s3://#{backend.name}/movies",
        type: :movies,
        monitored: true
      })

    download_dir = Path.join(tmp_dir, "download")
    File.mkdir_p!(download_dir)
    File.write!(Path.join(download_dir, "Invented.Film.2031.mkv"), "abc")

    {:ok, _} =
      Settings.create_download_client_config(%{
        name: "OutageClient",
        type: :qbittorrent,
        host: "nonexistent.invalid",
        port: 9999,
        username: "test",
        password: "test",
        enabled: true,
        priority: 1
      })

    movie = media_item_fixture(%{type: "movie", title: "Invented Film", year: 2031})

    download =
      download_fixture(%{
        media_item_id: movie.id,
        status: "completed",
        completed_at: DateTime.utc_now(),
        download_client: "OutageClient",
        download_client_id: "outage-1",
        library_path_id: library_path.id
      })

    %{bypass: bypass, download: download, download_dir: download_dir}
  end

  test "a 503 on the destination HEAD fails the import without uploading", ctx do
    # Any PUT or POST is an unexpected request and fails the test on exit.
    Bypass.stub(ctx.bypass, "HEAD", @ideal, &Plug.Conn.resp(&1, 503, ""))

    result =
      perform_job(MediaImport, %{
        "download_id" => ctx.download.id,
        "save_path" => ctx.download_dir
      })

    assert {:error, %Mydia.Storage.Error{kind: :provider}} = result
    assert Mydia.Library.list_media_files() == []
  end

  test "a 503 on the destination size check fails the import without uploading", ctx do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # First HEAD (existence) answers with a size; the second (size check) is down.
    Bypass.stub(ctx.bypass, "HEAD", @ideal, fn conn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if n == 1 do
        conn
        |> Plug.Conn.put_resp_header("content-length", "99")
        |> Plug.Conn.put_resp_header("last-modified", "Wed, 01 Oct 2031 10:00:00 GMT")
        |> Plug.Conn.resp(200, "")
      else
        Plug.Conn.resp(conn, 503, "")
      end
    end)

    result =
      perform_job(MediaImport, %{
        "download_id" => ctx.download.id,
        "save_path" => ctx.download_dir
      })

    assert {:error, %Mydia.Storage.Error{kind: :provider}} = result
    assert Mydia.Library.list_media_files() == []
  end

  test "a 503 while probing a conflict name fails the import without uploading", ctx do
    # The ideal name exists with other content; every suffixed candidate is
    # unreachable.
    Bypass.stub(ctx.bypass, "HEAD", @ideal, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "99")
      |> Plug.Conn.put_resp_header("last-modified", "Wed, 01 Oct 2031 10:00:00 GMT")
      |> Plug.Conn.resp(200, "")
    end)

    Bypass.stub(ctx.bypass, "HEAD", @conflict, &Plug.Conn.resp(&1, 503, ""))

    result =
      perform_job(MediaImport, %{
        "download_id" => ctx.download.id,
        "save_path" => ctx.download_dir
      })

    assert {:error, %Mydia.Storage.Error{kind: :provider}} = result
  end
end
