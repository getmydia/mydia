defmodule Mydia.Library.MetadataMatcherFallbackTest do
  @moduledoc """
  A show the library's provider does not carry is searched on the other one.
  async: false because Mydia.Metadata.Cache is a global ETS table.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Metadata.Cache

  @tvdb_search "/tvdb/search"
  @tmdb_tv_search "/tmdb/tv/search"

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000}
    }

    Cache.clear()
    on_exit(fn -> Cache.clear() end)
    {:ok, bypass: bypass, config: config}
  end

  defp stub(bypass, path, status \\ 200, body) do
    Bypass.stub(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  defp tv(title, year),
    do: %{type: :tv_show, title: title, year: year, season: 1, episodes: [1], confidence: 1.0}

  @tmdb_hit %{"id" => 880_001, "name" => "Saltmarsh Kitchen", "first_air_date" => "2021-04-02"}

  test "TVDB empty, TMDB hit: a TMDB match", %{bypass: bypass, config: config} do
    stub(bypass, @tvdb_search, %{"data" => []})
    stub(bypass, @tmdb_tv_search, %{"results" => [@tmdb_hit]})

    assert {:ok, match} =
             MetadataMatcher.match_tv_show(tv("Saltmarsh Kitchen", 2021), config, provider: :tvdb)

    assert match.provider_type == :tmdb
    assert match.provider_id == "880001"
  end

  test "a TVDB error is returned without trying TMDB", %{bypass: bypass, config: config} do
    # 400 rather than 500: the relay client retries 5xx with backoff.
    stub(bypass, @tvdb_search, 400, %{"error" => "boom"})

    Bypass.stub(bypass, "GET", @tmdb_tv_search, fn _conn ->
      flunk("TMDB must not be searched when TVDB errored")
    end)

    assert {:error, _} =
             MetadataMatcher.match_tv_show(tv("Saltmarsh Kitchen", 2021), config, provider: :tvdb)
  end

  test "no provider given: no fallback", %{bypass: bypass, config: config} do
    stub(bypass, @tvdb_search, %{"data" => []})

    Bypass.stub(bypass, "GET", @tmdb_tv_search, fn _conn ->
      flunk("TMDB must not be searched without a library provider")
    end)

    assert {:error, :no_matches_found} =
             MetadataMatcher.match_tv_show(tv("Saltmarsh Kitchen", 2021), config)
  end

  test "both empty: still no match", %{bypass: bypass, config: config} do
    stub(bypass, @tvdb_search, %{"data" => []})
    stub(bypass, @tmdb_tv_search, %{"results" => []})

    assert {:error, :no_matches_found} =
             MetadataMatcher.match_tv_show(tv("Saltmarsh Kitchen", 2021), config, provider: :tvdb)
  end
end
