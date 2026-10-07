defmodule MydiaWeb.Api.RangeHelperSourceTest.WirePlug do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, source: source), do: MydiaWeb.Api.RangeHelper.send_source_ranged(conn, source)
end

defmodule MydiaWeb.Api.RangeHelperSourceTest do
  use MydiaWeb.ConnCase, async: true

  @moduletag :s3

  alias MydiaWeb.Api.RangeHelper
  alias MydiaWeb.Api.RangeHelperSourceTest.WirePlug

  setup do
    loc = Mydia.S3Helpers.unique_location(Mydia.S3Helpers.backend())
    on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)
    Mydia.S3Helpers.put_object!(loc, "f.mp4", "0123456789")
    {:ok, source} = Mydia.Storage.source(loc, "f.mp4")
    %{source: source}
  end

  test "full body without a Range header", %{conn: conn, source: s} do
    conn = RangeHelper.send_source_ranged(conn, s)
    assert conn.status == 200
    assert get_resp_header(conn, "content-length") == ["10"]
    assert conn.resp_body == "0123456789"
  end

  test "206 for a range, a suffix range and an end past EOF", %{conn: conn, source: s} do
    for {range, body, cr} <- [
          {"bytes=2-4", "234", "bytes 2-4/10"},
          {"bytes=-3", "789", "bytes 7-9/10"},
          {"bytes=8-100", "89", "bytes 8-9/10"}
        ] do
      c = conn |> put_req_header("range", range) |> RangeHelper.send_source_ranged(s)
      assert c.status == 206
      assert get_resp_header(c, "content-range") == [cr]
      assert c.resp_body == body
    end
  end

  test "416 for an unsatisfiable range", %{conn: conn, source: s} do
    c = conn |> put_req_header("range", "bytes=50-60") |> RangeHelper.send_source_ranged(s)
    assert c.status == 416
    assert get_resp_header(c, "content-range") == ["bytes */10"]
  end

  test "404 for an object that is gone", %{conn: conn, source: s} do
    {:ok, gone} = Mydia.Storage.source(s.location, "missing.mp4")
    assert RangeHelper.send_source_ranged(conn, gone).status == 404
  end

  describe "on the wire (Bandit)" do
    setup %{source: source} do
      pid =
        start_supervised!({Bandit, plug: {WirePlug, source: source}, port: 0, ip: :loopback})

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      %{base: "http://127.0.0.1:#{port}/"}
    end

    defp wire_get(base, headers) do
      Req.get!(base, headers: headers, retry: false, decode_body: false, raw: true)
    end

    test "ranged response carries content-length, no chunking", %{base: base} do
      r = wire_get(base, range: "bytes=0-3")
      assert r.status == 206
      assert Req.Response.get_header(r, "content-length") == ["4"]
      assert Req.Response.get_header(r, "transfer-encoding") == []
      assert Req.Response.get_header(r, "content-range") == ["bytes 0-3/10"]
      assert r.body == "0123"
    end

    test "suffix range", %{base: base} do
      r = wire_get(base, range: "bytes=-3")
      assert r.status == 206
      assert Req.Response.get_header(r, "content-length") == ["3"]
      assert Req.Response.get_header(r, "transfer-encoding") == []
      assert Req.Response.get_header(r, "content-range") == ["bytes 7-9/10"]
      assert r.body == "789"
    end

    test "no range", %{base: base} do
      r = wire_get(base, [])
      assert r.status == 200
      assert Req.Response.get_header(r, "content-length") == ["10"]
      assert Req.Response.get_header(r, "transfer-encoding") == []
      assert Req.Response.get_header(r, "content-range") == []
      assert r.body == "0123456789"
    end
  end
end
