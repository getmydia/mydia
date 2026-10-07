defmodule Mydia.Storage.S3.RequestTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage
  alias Mydia.Storage.{Error, Location}
  alias Mydia.Storage.S3.Request

  setup do
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

    %{
      bypass: bypass,
      backend: backend,
      location: Location.s3(backend, "movies/", "s3://m/movies")
    }
  end

  test "path-style and virtual-host URLs, with key encoding", %{backend: b} do
    assert Request.object_url(b, "movies/A Film (2031)/a.mkv") ==
             "#{b.endpoint}/lib/movies/A%20Film%20%282031%29/a.mkv"

    vb = %{b | endpoint: "https://s3.example.test", path_style: false}
    assert Request.object_url(vb, "x.mkv") == "https://lib.s3.example.test/x.mkv"
  end

  test "requests are SigV4-signed", %{bypass: bypass, location: loc} do
    Bypass.expect_once(bypass, "HEAD", "/lib/movies/a.mkv", fn conn ->
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256 Credential=AKID/"
      assert auth =~ "/us-east-1/s3/aws4_request"
      refute auth =~ "SECRET"

      # Plug resets content-length for an empty body; for HEAD it keeps the
      # length of the body it was given and drops the body itself.
      conn
      |> Plug.Conn.put_resp_header("last-modified", "Wed, 01 Oct 2031 10:00:00 GMT")
      |> Plug.Conn.resp(200, "12345")
    end)

    {:ok, src} = Storage.source(loc, "a.mkv")
    assert {:ok, %{size: 5}} = Storage.stat(src)
  end

  test "ListObjectsV2 follows continuation tokens", %{bypass: bypass, location: loc} do
    Bypass.expect(bypass, "GET", "/lib", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["list-type"] == "2"
      assert conn.query_params["prefix"] == "movies/"

      body =
        case conn.query_params["continuation-token"] do
          nil -> list_xml(["movies/a.mkv"], "tok1")
          "tok1" -> list_xml(["movies/b/c.mkv"], nil)
        end

      Plug.Conn.resp(conn, 200, body)
    end)

    assert {:ok, entries} = Storage.list(loc)
    assert entries |> Enum.map(& &1.relative_path) |> Enum.sort() == ["a.mkv", "b/c.mkv"]
  end

  test "maps provider errors", %{bypass: bypass, location: loc} do
    Bypass.expect(bypass, "HEAD", "/lib/movies/forbidden.mkv", &Plug.Conn.resp(&1, 403, ""))
    Bypass.expect(bypass, "HEAD", "/lib/movies/missing.mkv", &Plug.Conn.resp(&1, 404, ""))

    {:ok, f} = Storage.source(loc, "forbidden.mkv")
    {:ok, m} = Storage.source(loc, "missing.mkv")
    assert {:error, %Error{kind: :forbidden}} = Storage.stat(f)
    assert {:error, %Error{kind: :not_found}} = Storage.stat(m)

    Bypass.down(bypass)
    assert {:error, %Error{kind: :unreachable, message: msg}} = Storage.stat(m)
    refute msg =~ "SECRET"
  end

  test "input/1 is a presigned URL that redacts cleanly", %{bypass: bypass, location: loc} do
    Bypass.expect_once(bypass, "HEAD", "/lib/movies/a.mkv", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "1")
      |> Plug.Conn.resp(200, "")
    end)

    {:ok, src} = Storage.source(loc, "a.mkv")
    assert {:ok, url} = Storage.input(src)
    assert url =~ "X-Amz-Signature="
    assert url =~ "X-Amz-Expires=43200"
    assert Storage.redact(url) == "http://localhost:#{bypass.port}/lib/movies/a.mkv"
  end

  defp list_xml(keys, token) do
    contents =
      Enum.map_join(keys, fn k ->
        "<Contents><Key>#{k}</Key><Size>3</Size><LastModified>2031-10-01T10:00:00.000Z</LastModified></Contents>"
      end)

    truncated = if token, do: "true", else: "false"
    next = if token, do: "<NextContinuationToken>#{token}</NextContinuationToken>", else: ""

    ~s(<?xml version="1.0"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      "<IsTruncated>#{truncated}</IsTruncated>#{next}#{contents}</ListBucketResult>"
  end
end
