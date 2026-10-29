defmodule Mydia.RelayStubHelpers do
  @moduledoc """
  Points the metadata relay at a Bypass server for one test.

  The relay URL is global application env, so a test using this must not be
  `async: true`. The previous value is restored on exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Opens a Bypass server and makes it the metadata relay until the test exits."
  def point_relay_at_bypass do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mydia, :metadata_relay_url, previous),
        else: Application.delete_env(:mydia, :metadata_relay_url)
    end)

    bypass
  end

  @doc """
  Serves a movie that belongs to a TMDB collection, and the collection itself,
  from `bypass`.

  `part_ids` are the collection's member TMDB ids. The cached lookups both
  responses feed are cleared when the test exits.
  """
  def stub_franchise_movie(bypass, tmdb_id, collection_id, part_ids) do
    language = Mydia.Metadata.default_relay_config().options.language

    on_exit(fn ->
      Mydia.Metadata.Cache.delete("fetch_by_ref:tmdb:#{tmdb_id}:movie:#{language}::official")
      Mydia.Metadata.Cache.delete("collection:metadata_relay:#{collection_id}:#{language}")
    end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      json(conn, %{
        "id" => tmdb_id,
        "title" => "Starfall Protocol #{tmdb_id}",
        "release_date" => "2031-03-04",
        "overview" => "x",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "belongs_to_collection" => %{"id" => collection_id, "name" => "Starfall"}
      })
    end)

    Bypass.stub(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      json(conn, %{
        "id" => collection_id,
        "name" => "Starfall",
        "parts" =>
          Enum.map(
            part_ids,
            &%{"id" => &1, "title" => "Starfall Protocol #{&1}", "release_date" => "2031-01-01"}
          )
      })
    end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
