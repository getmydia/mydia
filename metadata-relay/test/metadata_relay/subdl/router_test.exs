defmodule MetadataRelay.SubDL.RouterTest do
  use ExUnit.Case, async: false

  # put_req_header/3 comes from Plug.Conn. Plug 1.18 deprecates `use Plug.Test`,
  # and the rest of this suite already calls Plug.Test.conn/3 fully qualified,
  # so follow that rather than reintroducing the deprecated `use`.
  import Plug.Conn, only: [put_req_header: 3]

  alias MetadataRelay.Router

  @moduletag :capture_log

  @opts Router.init([])

  defp conn(method, path, body \\ nil), do: Plug.Test.conn(method, path, body)

  setup do
    System.put_env("SUBDL_API_KEY", "test_key")
    System.put_env("PHX_HOST", "relay.example.test")

    # Avoid cross-test pollution: the router pipeline caches successful GET
    # responses in a shared ETS table, keyed by method:path:query_string, and
    # more than one test here hits the same download id.
    MetadataRelay.Cache.clear()

    on_exit(fn ->
      System.delete_env("SUBDL_API_KEY")
      System.delete_env("PHX_HOST")
      Application.delete_env(:metadata_relay, :subdl_http_adapter)
    end)

    :ok
  end

  defp stub(fun), do: Application.put_env(:metadata_relay, :subdl_http_adapter, fun)

  defp zip(entries) do
    {:ok, {_name, binary}} =
      :zip.create(~c"s.zip", Enum.map(entries, fn {n, c} -> {to_charlist(n), c} end), [:memory])

    binary
  end

  test "search returns SubDL results in the existing wire shape" do
    stub(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => true,
           "subtitles" => [
             %{
               "release_name" => "R",
               "url" => "/subtitle/1-2.zip?api_key=k",
               "language" => "EN",
               "hi" => false
             }
           ]
         }
       )}
    end)

    conn =
      :post
      |> conn("/api/v1/subtitles/search", Jason.encode!(%{imdb_id: "0133093", languages: "en"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 200
    assert %{"subtitles" => [subtitle]} = Jason.decode!(conn.resp_body)
    assert subtitle["release"] == "R"
  end

  test "download-url advertises the relay's own host" do
    id = MetadataRelay.SubDL.FileId.encode("/subtitle/1-2.zip")

    conn = Router.call(conn(:get, "/api/v1/subtitles/download-url/#{id}"), @opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["download_url"] == "https://relay.example.test/api/v1/subtitles/download/#{id}"
  end

  test "download returns plain subtitle bytes, not the archive" do
    stub(fn request ->
      {request, Req.Response.new(status: 200, body: zip([{"m.srt", "plain text"}]))}
    end)

    id = MetadataRelay.SubDL.FileId.encode("/subtitle/1-2.zip")
    conn = Router.call(conn(:get, "/api/v1/subtitles/download/#{id}"), @opts)

    assert conn.status == 200
    assert conn.resp_body == "plain text"
  end

  test "download rejects an id that is not a SubDL archive" do
    stub(fn _request -> flunk("must not fetch an unvalidated id") end)

    id = Base.url_encode64("https://evil.example.com/x.zip", padding: false)
    conn = Router.call(conn(:get, "/api/v1/subtitles/download/#{id}"), @opts)

    assert conn.status == 400
  end

  test "download reports an archive holding no subtitle" do
    stub(fn request -> {request, Req.Response.new(status: 200, body: zip([{"r.txt", "no"}]))} end)

    id = MetadataRelay.SubDL.FileId.encode("/subtitle/1-2.zip")
    conn = Router.call(conn(:get, "/api/v1/subtitles/download/#{id}"), @opts)

    assert conn.status == 502
  end

  test "search reports not-configured when the key is absent" do
    System.delete_env("SUBDL_API_KEY")

    conn =
      :post
      |> conn("/api/v1/subtitles/search", Jason.encode!(%{imdb_id: "0133093"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert conn.status == 503
  end
end
