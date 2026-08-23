defmodule MetadataRelay.AtomExhaustionTest do
  @moduledoc """
  Regression tests for T-020/T-237: `extract_query_params/1` and
  `extract_body_params/1` used to call `String.to_atom/1` on every
  caller-supplied param key name, with no allowlist. Atoms are never garbage
  collected and the BEAM's default atom table ceiling is ~1,048,576, so
  enough distinct key names (from a fully unauthenticated caller, on any of
  the 40 affected routes) would crash the relay every Mydia install shares.

  These tests hit the routes through the full `Router` pipeline and assert
  `:erlang.system_info(:atom_count)` does not move, while also asserting
  arbitrary/unknown param names still reach the upstream request -- proving
  the fix is a representation change (string-keyed maps, not atom
  conversion), not an allowlist that would silently drop unrecognized
  parameters like `append_to_response`.
  """

  use ExUnit.Case, async: false

  alias MetadataRelay.Router
  alias MetadataRelay.Test.TMDBHelpers

  @moduletag :capture_log

  setup do
    System.put_env("TMDB_API_KEY", "test_api_key_12345")
    System.put_env("SUBDL_API_KEY", "test_key")
    MetadataRelay.Cache.clear()

    # Avoid cross-test pollution from the (T-263) proxy rate limiter, which
    # is a shared, named ETS table keyed on client IP -- every test here
    # runs as the same loopback "caller".
    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)

    on_exit(fn ->
      TMDBHelpers.clear_tmdb_adapter()
      System.delete_env("TMDB_API_KEY")
      System.delete_env("SUBDL_API_KEY")
      Application.delete_env(:metadata_relay, :subdl_http_adapter)
    end)

    :ok
  end

  # A key guaranteed never to have appeared anywhere else in this BEAM
  # instance's lifetime, so if it were ever atomized it would necessarily be
  # a *new* atom, not a coincidental hit on an existing one.
  defp novel_key do
    "novel_param_#{System.unique_integer([:positive, :monotonic])}_#{:rand.uniform(1_000_000)}"
  end

  describe "GET proxy routes never atomize caller-supplied query param names" do
    test "many never-seen-before query param names create no new atoms" do
      TMDBHelpers.set_tmdb_adapter(fn request ->
        {request, Req.Response.new(status: 200, body: %{"results" => []})}
      end)

      # Warm up the code path once on a fixed, non-novel query string first:
      # first-time module loads/format-string compilation elsewhere in the
      # stack can themselves mint a handful of atoms, and that would be
      # unrelated noise this test should not be sensitive to.
      warmup_conn = Plug.Test.conn(:get, "/tmdb/movies/search?query=warmup") |> Router.call([])
      assert warmup_conn.status == 200
      MetadataRelay.Cache.clear()

      novel_keys = for _ <- 1..50, do: novel_key()

      query =
        novel_keys
        |> Enum.with_index()
        |> Enum.map_join("&", fn {key, i} -> "#{key}=v#{i}" end)

      before_count = :erlang.system_info(:atom_count)

      conn = Plug.Test.conn(:get, "/tmdb/movies/search?#{query}") |> Router.call([])

      after_count = :erlang.system_info(:atom_count)

      assert conn.status == 200

      assert after_count == before_count,
             "expected no new atoms from 50 novel query param names; " <>
               "before=#{before_count} after=#{after_count} (grew by #{after_count - before_count})"
    end

    test "an arbitrary, unrecognized param name is still forwarded verbatim to TMDB" do
      test_pid = self()

      TMDBHelpers.set_tmdb_adapter(fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: %{"results" => []})}
      end)

      key = novel_key()

      conn =
        Plug.Test.conn(:get, "/tmdb/movies/search?query=batman&#{key}=hello")
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}

      decoded = URI.decode_query(url.query || "")
      assert decoded[key] == "hello"
      assert decoded["query"] == "batman"
      assert decoded["api_key"] == "test_api_key_12345"
    end
  end

  describe "POST /api/v1/subtitles/search never atomizes caller-supplied body field names" do
    test "many never-seen-before JSON body field names create no new atoms" do
      Application.put_env(:metadata_relay, :subdl_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
      end)

      warmup_conn =
        :post
        |> Plug.Test.conn("/api/v1/subtitles/search", Jason.encode!(%{"imdb_id" => "warmup"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Router.call([])

      assert warmup_conn.status == 200

      body =
        for _ <- 1..50, into: %{"imdb_id" => "0133093"} do
          {novel_key(), "value"}
        end

      before_count = :erlang.system_info(:atom_count)

      conn =
        :post
        |> Plug.Test.conn("/api/v1/subtitles/search", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Router.call([])

      after_count = :erlang.system_info(:atom_count)

      assert conn.status == 200

      assert after_count == before_count,
             "expected no new atoms from 50 novel JSON body field names; " <>
               "before=#{before_count} after=#{after_count} (grew by #{after_count - before_count})"
    end

    test "the allowlisted identity field is still honored alongside unknown extra fields" do
      test_pid = self()

      Application.put_env(:metadata_relay, :subdl_http_adapter, fn request ->
        send(test_pid, {:request_url, request.url})
        {request, Req.Response.new(status: 200, body: %{"status" => true, "subtitles" => []})}
      end)

      body =
        %{"imdb_id" => "0133093", "languages" => "en"}
        |> Map.put(novel_key(), "ignored")

      conn =
        :post
        |> Plug.Test.conn("/api/v1/subtitles/search", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Router.call([])

      assert conn.status == 200
      assert_received {:request_url, url}
      assert url.query =~ "imdb_id=tt0133093"
    end
  end
end
