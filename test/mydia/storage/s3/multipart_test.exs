defmodule Mydia.Storage.S3.MultipartTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage
  alias Mydia.Storage.{Error, Location}

  @mib 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    bypass = Bypass.open()

    backend = %StorageBackend{
      name: "m",
      endpoint: "http://localhost:#{bypass.port}",
      region: "us-east-1",
      bucket: "lib",
      access_key_id: "AKID",
      secret_access_key: "SECRET",
      path_style: true
    }

    file = Path.join(tmp_dir, "big.mkv")
    File.write!(file, :binary.copy("b", 11 * @mib))

    %{bypass: bypass, location: Location.s3(backend, "movies/", "s3://m/movies"), big: file}
  end

  defp initiate(bypass) do
    Bypass.expect_once(bypass, "POST", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "uploads") do
        Plug.Conn.resp(
          conn,
          200,
          "<InitiateMultipartUploadResult><UploadId>U1</UploadId></InitiateMultipartUploadResult>"
        )
      else
        Plug.Conn.resp(conn, 200, "<Error><Code>InternalError</Code></Error>")
      end
    end)
  end

  test "a failed part aborts the upload and completes nothing", %{
    bypass: bypass,
    location: loc,
    big: big
  } do
    initiate(bypass)
    test_pid = self()

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)

      case conn.query_params["partNumber"] do
        "1" -> conn |> Plug.Conn.put_resp_header("etag", "\"p1\"") |> Plug.Conn.resp(200, "")
        _ -> Plug.Conn.resp(conn, 403, "")
      end
    end)

    Bypass.expect_once(bypass, "DELETE", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:aborted, conn.query_params["uploadId"]})
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert {:error, %Error{kind: :forbidden}} = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received {:aborted, "U1"}
  end

  test "a Complete answered with an Error body aborts", %{
    bypass: bypass,
    location: loc,
    big: big
  } do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "uploads") do
        Plug.Conn.resp(
          conn,
          200,
          "<InitiateMultipartUploadResult><UploadId>U1</UploadId></InitiateMultipartUploadResult>"
        )
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "<PartNumber>3</PartNumber>"
        Plug.Conn.resp(conn, 200, "<Error><Code>InternalError</Code></Error>")
      end
    end)

    Bypass.expect(bypass, "PUT", "/lib/movies/big.mkv", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 20 * @mib)
      n = conn.query_params["partNumber"]
      conn |> Plug.Conn.put_resp_header("etag", "\"p#{n}\"") |> Plug.Conn.resp(200, "")
    end)

    Bypass.expect_once(bypass, "DELETE", "/lib/movies/big.mkv", fn conn ->
      send(test_pid, :aborted)
      Plug.Conn.resp(conn, 204, "")
    end)

    {:ok, dest} = Storage.source(loc, "big.mkv")
    assert {:error, %Error{kind: :provider}} = Storage.put_file(dest, big, part_size: 5 * @mib)
    assert_received :aborted
  end
end
