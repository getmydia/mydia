defmodule MetadataRelay.Plug.CacheTest do
  use ExUnit.Case, async: false

  # put_req_header/3 comes from Plug.Conn. Plug 1.18 deprecates `use Plug.Test`,
  # so follow the rest of the suite and call Plug.Test.conn/3 fully qualified.
  import Plug.Conn, only: [put_req_header: 3]

  alias MetadataRelay.Router
  alias MetadataRelay.Test.TMDBHelpers

  @moduletag :capture_log

  @opts Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)

    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)

    System.put_env("SUBDL_API_KEY", "test_key")
    System.put_env("TMDB_API_KEY", "test_api_key_12345")
    MetadataRelay.Cache.clear()

    on_exit(fn ->
      System.delete_env("SUBDL_API_KEY")
      System.delete_env("TMDB_API_KEY")
      Application.delete_env(:metadata_relay, :subdl_http_adapter)
      TMDBHelpers.clear_tmdb_adapter()
      MetadataRelay.Cache.clear()
    end)

    :ok
  end

  # Counts upstream calls so a test can assert how many requests actually left
  # the relay, which is the only thing that draws on the shared SubDL key.
  defp counting_subdl_stub do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:metadata_relay, :subdl_http_adapter, fn request ->
      Agent.update(counter, &(&1 + 1))

      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "status" => true,
           "subtitles" => [
             %{
               "release_name" => "R",
               "url" => "/subtitle/1-2.zip",
               "language" => "EN",
               "hi" => false
             }
           ]
         }
       )}
    end)

    counter
  end

  # As above, but answering with a caller-supplied body, so a test can count the
  # upstream calls made while SubDL is misbehaving.
  defp counting_subdl_stub(body) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Application.put_env(:metadata_relay, :subdl_http_adapter, fn request ->
      Agent.update(counter, &(&1 + 1))
      {request, Req.Response.new(status: 200, body: body)}
    end)

    counter
  end

  defp calls(counter), do: Agent.get(counter, & &1)

  # The TTL the plug chose is not visible in the response, so read the expiry
  # the in-memory adapter recorded for the stored search entry.
  defp search_entry_ttl_ms do
    :metadata_relay_cache
    |> :ets.tab2list()
    |> Enum.find_value(fn {key, _value, expires_at} ->
      if String.starts_with?(key, "POST:/api/v1/subtitles/search:") do
        DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
      end
    end)
  end

  defp search(json_body) do
    :post
    |> Plug.Test.conn("/api/v1/subtitles/search", json_body)
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp crash_report(body) do
    :post
    |> Plug.Test.conn("/crashes/report", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  describe "POST /api/v1/subtitles/search" do
    test "identical searches reach SubDL once" do
      counter = counting_subdl_stub()
      body = Jason.encode!(%{imdb_id: "0133093", languages: "en"})

      first = search(body)
      second = search(body)
      third = search(body)

      assert first.status == 200
      assert second.status == 200
      assert third.status == 200
      assert second.resp_body == first.resp_body
      assert third.resp_body == first.resp_body

      assert calls(counter) == 1
    end

    test "different searches reach SubDL once each" do
      counter = counting_subdl_stub()

      assert search(Jason.encode!(%{imdb_id: "0133093", languages: "en"})).status == 200
      assert search(Jason.encode!(%{imdb_id: "0111161", languages: "en"})).status == 200

      assert calls(counter) == 2
    end

    test "the same criteria in a different key order share one cache entry" do
      counter = counting_subdl_stub()

      assert search(~s({"imdb_id":"0133093","languages":"en"})).status == 200
      assert search(~s({"languages":"en","imdb_id":"0133093"})).status == 200

      assert calls(counter) == 1
    end

    test "a language change is a different search" do
      counter = counting_subdl_stub()

      assert search(Jason.encode!(%{imdb_id: "0133093", languages: "en"})).status == 200
      assert search(Jason.encode!(%{imdb_id: "0133093", languages: "fr"})).status == 200

      assert calls(counter) == 2
    end

    test "an error response is not cached" do
      System.delete_env("SUBDL_API_KEY")

      assert search(Jason.encode!(%{imdb_id: "0133093"})).status == 503

      counter = counting_subdl_stub()
      System.put_env("SUBDL_API_KEY", "test_key")

      assert search(Jason.encode!(%{imdb_id: "0133093"})).status == 200
      assert calls(counter) == 1
    end

    # A captcha interstitial or CDN block page is an upstream anomaly, not a
    # title with no subtitles. Storing it would answer "nothing found" for the
    # whole search TTL, for every install, with nothing to invalidate it.
    test "an anomalous upstream response is not cached" do
      counter = counting_subdl_stub("<html>Just a moment...</html>")
      body = Jason.encode!(%{imdb_id: "0133093", languages: "en"})

      first = search(body)
      second = search(body)

      refute first.status in 200..299
      refute second.status in 200..299
      assert calls(counter) == 2

      # And once SubDL recovers, the next search still reaches it.
      recovered = counting_subdl_stub()

      assert search(body).status == 200
      assert calls(recovered) == 1
    end

    test "an empty result expires within the hour, a non-empty one keeps the search TTL" do
      Application.put_env(:metadata_relay, :subdl_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{"status" => false, "error" => "no"})}
      end)

      assert search(Jason.encode!(%{imdb_id: "0133093"})).status == 200
      assert search_entry_ttl_ms() <= :timer.hours(1)

      MetadataRelay.Cache.clear()
      counting_subdl_stub()

      assert search(Jason.encode!(%{imdb_id: "0133093"})).status == 200
      assert search_entry_ttl_ms() > :timer.hours(24)
    end
  end

  describe "subtitle_search_cache_key/2" do
    # The cache stores the transformed response body. A deploy that changes
    # `SubDL.Handler.transform_subtitle/2`'s emitted shape does not otherwise
    # invalidate what is already cached, so a popular title would keep
    # serving the old shape for the rest of the 7-day search TTL. Folding the
    # wire-format version into the key means a version bump alone is enough
    # to invalidate it, with no manual flush.
    test "a different wire-format version produces a different cache key" do
      key_v1 = MetadataRelay.Plug.Cache.subtitle_search_cache_key("fingerprint", 1)
      key_v2 = MetadataRelay.Plug.Cache.subtitle_search_cache_key("fingerprint", 2)

      refute key_v1 == key_v2
    end

    test "the same version and fingerprint produce the same cache key" do
      assert MetadataRelay.Plug.Cache.subtitle_search_cache_key("fingerprint", 1) ==
               MetadataRelay.Plug.Cache.subtitle_search_cache_key("fingerprint", 1)
    end
  end

  describe "other POST routes" do
    test "POST /crashes/report is never cached, so every report is stored" do
      report = %{
        "error_type" => "RuntimeError",
        "error_message" => "boom",
        "stacktrace" => [%{"file" => "lib/mydia/a.ex", "line" => 10, "function" => "handle/1"}]
      }

      assert crash_report(report).status == 201
      assert crash_report(report).status == 201

      # Identical reports collapse into one ErrorTracker error but must record
      # one occurrence each. A cached 201 would swallow the second report
      # entirely, which is why this route must never enter the cache.
      assert MetadataRelay.Repo.aggregate(ErrorTracker.Occurrence, :count) == 2
    end
  end

  describe "GET routes" do
    test "successful GET responses are still cached" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      TMDBHelpers.set_tmdb_adapter(fn request ->
        Agent.update(counter, &(&1 + 1))
        {request, Req.Response.new(status: 200, body: %{"id" => 550, "title" => "Fight Club"})}
      end)

      first = Router.call(Plug.Test.conn(:get, "/tmdb/movies/550"), @opts)
      second = Router.call(Plug.Test.conn(:get, "/tmdb/movies/550"), @opts)

      assert first.status == 200
      assert second.status == 200
      assert second.resp_body == first.resp_body
      assert calls(counter) == 1
    end
  end
end
