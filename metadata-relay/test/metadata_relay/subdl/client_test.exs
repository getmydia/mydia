defmodule MetadataRelay.SubDL.ClientTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.SubDL.Client
  import ExUnit.CaptureIO

  @moduletag :capture_log

  setup do
    System.put_env("SUBDL_API_KEY", "test_key")

    on_exit(fn ->
      System.delete_env("SUBDL_API_KEY")
      Application.delete_env(:metadata_relay, :subdl_http_adapter)
    end)

    :ok
  end

  defp stub(fun), do: Application.put_env(:metadata_relay, :subdl_http_adapter, fun)

  test "sends the api key and returns the decoded body" do
    stub(fn request ->
      assert request.url.path == "/api/v1/subtitles"
      assert request.url.query =~ "api_key=test_key"
      {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
    end)

    assert {:ok, %{"status" => true}} = Client.search(imdb_id: "tt0133093")
  end

  test "uses custom HTTP adapters without Req deprecation warnings" do
    stub(fn request ->
      {request, Req.Response.new(status: 200, body: %{"status" => true})}
    end)

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, %{"status" => true}} = Client.search(imdb_id: "tt0133093")
      end)

    refute stderr =~ "setting `adapter` to a function is deprecated"
  end

  test "reports a missing api key as not configured" do
    System.delete_env("SUBDL_API_KEY")

    assert {:error, :not_configured} = Client.search(imdb_id: "tt0133093")
  end

  test "treats an empty api key as not configured" do
    System.put_env("SUBDL_API_KEY", "")

    assert {:error, :not_configured} = Client.search(imdb_id: "tt0133093")
  end

  test "surfaces a rate limit with its retry-after" do
    stub(fn request ->
      {request, Req.Response.new(status: 429, headers: %{"retry-after" => ["30"]}, body: "")}
    end)

    assert {:error, {:rate_limited, "30"}} = Client.search(imdb_id: "tt0133093")
  end

  # The archive host takes no credentials, which is the property that makes a
  # single shared relay key workable.
  test "fetches an archive without sending the api key" do
    stub(fn request ->
      assert request.url.host == "dl.subdl.com"
      assert request.url.query in [nil, ""]
      {request, Req.Response.new(status: 200, body: "PK\x03\x04binary")}
    end)

    assert {:ok, "PK\x03\x04binary"} = Client.fetch_archive("/subtitle/1-2.zip")
  end

  test "reports an archive that is not available" do
    stub(fn request -> {request, Req.Response.new(status: 404, body: "")} end)

    assert {:error, {:http_error, 404, _}} = Client.fetch_archive("/subtitle/1-2.zip")
  end
end
