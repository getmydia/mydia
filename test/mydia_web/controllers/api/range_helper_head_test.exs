defmodule MydiaWeb.Api.RangeHelperHeadTest.EndpointLikePlug do
  @moduledoc false
  # Same order as MydiaWeb.Endpoint: record the method, then Plug.Head.
  use Plug.Builder

  plug MydiaWeb.Plugs.RecordHeadRequest
  plug Plug.Head
  plug :serve

  def serve(conn, _opts), do: MydiaWeb.Api.RangeHelper.send_source_ranged(conn, conn.private.src)
end

defmodule MydiaWeb.Api.RangeHelperHeadTest.FakeBucket do
  @moduledoc false
  # Answers the stat HEAD of a 10 byte object and reports any GET to the test.
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "HEAD"} = conn, test: _test) do
    conn
    |> Plug.Conn.put_resp_header("content-length", "10")
    |> Plug.Conn.put_resp_header("last-modified", "Wed, 07 Oct 2026 10:00:00 GMT")
    |> Plug.Conn.send_resp(200, "")
  end

  def call(conn, test: test) do
    send(test, {:bucket_request, conn.method})
    Plug.Conn.send_resp(conn, 500, "unexpected")
  end
end

defmodule MydiaWeb.Api.RangeHelperHeadTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.Location
  alias MydiaWeb.Api.RangeHelperHeadTest.{EndpointLikePlug, FakeBucket}
  alias MydiaWeb.Plugs.RecordHeadRequest

  describe "RecordHeadRequest" do
    test "flags a HEAD before Plug.Head rewrites it" do
      conn = Plug.Test.conn("HEAD", "/") |> RecordHeadRequest.call([]) |> Plug.Head.call([])
      assert conn.method == "GET"
      assert RecordHeadRequest.head_request?(conn)
    end

    test "does not flag a GET" do
      conn = Plug.Test.conn("GET", "/") |> RecordHeadRequest.call([])
      refute RecordHeadRequest.head_request?(conn)
    end

    test "the real endpoint sets the flag for a HEAD", %{conn: conn} do
      assert RecordHeadRequest.head_request?(head(conn, "/health"))
      refute RecordHeadRequest.head_request?(get(conn, "/health"))
    end
  end

  describe "HEAD of an S3 source, on the wire" do
    setup do
      fake = start_supervised!({Bandit, plug: {FakeBucket, test: self()}, port: 0, ip: :loopback})
      {:ok, {_ip, bucket_port}} = ThousandIsland.listener_info(fake)

      backend = %StorageBackend{
        name: "fake",
        endpoint: "http://127.0.0.1:#{bucket_port}",
        region: "us-east-1",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s",
        path_style: true
      }

      {:ok, source} = Mydia.Storage.source(Location.s3(backend, "p/", "s3://fake/p/"), "f.mp4")

      app =
        start_supervised!(
          {Bandit,
           plug: fn conn, _ ->
             EndpointLikePlug.call(Plug.Conn.put_private(conn, :src, source), [])
           end,
           port: 0,
           ip: :loopback},
          id: :app
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(app)
      %{base: "http://127.0.0.1:#{port}/"}
    end

    defp wire_head(base, headers),
      do: Req.head!(base, headers: headers, retry: false, decode_body: false)

    test "range HEAD answers 206 with the GET headers and never GETs the bucket", %{base: base} do
      r = wire_head(base, range: "bytes=2-4")
      assert r.status == 206
      assert Req.Response.get_header(r, "content-length") == ["3"]
      assert Req.Response.get_header(r, "content-range") == ["bytes 2-4/10"]
      assert r.body == ""
      refute_received {:bucket_request, _}
    end

    test "plain HEAD answers 200 with the full length", %{base: base} do
      r = wire_head(base, [])
      assert r.status == 200
      assert Req.Response.get_header(r, "content-length") == ["10"]
      assert Req.Response.get_header(r, "accept-ranges") == ["bytes"]
      refute_received {:bucket_request, _}
    end
  end
end
