defmodule Mydia.Library.MetadataMatcherDirectLookupTest do
  @moduledoc """
  Covers the direct-lookup-by-folder-id path (e.g. a folder named
  `[tvdb-280619]`), specifically that the resulting match's metadata keeps
  the provider that actually served it.

  `lookup_tv_show_by_external_id/3` passes a TVDB `MediaMetadata` through
  `Map.from_struct/1` and back through `MediaMetadata.from_api_response/3`.
  That rewrap used to hardcode `provider: :tmdb` regardless of what actually
  produced the metadata, so a TVDB-sourced direct match came back tagged as
  if TMDB owned it.
  """

  use Mydia.DataCase, async: false

  alias Mydia.Library.MetadataMatcher
  alias Mydia.Metadata.Cache

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

  test "a direct TVDB folder-id match keeps the metadata tagged :tvdb", %{
    bypass: bypass,
    config: config
  } do
    tvdb_id = 280_619

    parsed = %{
      type: :tv_show,
      title: "Harbor Relay",
      year: 2020,
      season: 1,
      episodes: [1],
      confidence: 1.0,
      external_id: to_string(tvdb_id),
      external_provider: :tvdb
    }

    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      body = %{
        "data" => %{
          "id" => tvdb_id,
          "tvdb_id" => tvdb_id,
          "name" => "Harbor Relay",
          "overview" => "test overview",
          "first_air_date" => "2020-01-01",
          "genres" => [],
          "seasons" => []
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    assert {:ok, match} = MetadataMatcher.match_tv_show(parsed, config)
    assert match.match_type == :direct_id_lookup
    assert match.provider_type == :tvdb
    assert match.metadata.provider == :tvdb
  end
end
