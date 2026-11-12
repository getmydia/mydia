defmodule Mydia.Metadata.Provider.RelayTmdbMediaTypeTest do
  @moduledoc """
  TMDB numbers movies and shows independently, so one id can name both. A
  fetch that states its media type must reach TMDB even when the id was last
  seen as the other type; only a fetch that guessed its type is checked against
  `Mydia.Metadata.ProviderIDRegistry`.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay
  alias Mydia.Metadata.ProviderIDRegistry

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000, connect_timeout: 1_000}
    }

    # Offset past any real id: the registry is a process-global ETS table.
    tmdb_id = 900_000_000 + System.unique_integer([:positive])

    {:ok, bypass: bypass, config: config, tmdb_id: tmdb_id}
  end

  test "an explicit type is fetched even when the id was recorded as the other type", ctx do
    ProviderIDRegistry.record_id_type({:tmdb, ctx.tmdb_id}, :movie)

    Bypass.expect_once(ctx.bypass, "GET", "/tmdb/tv/shows/#{ctx.tmdb_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => ctx.tmdb_id, "name" => "Tidewater Bureau"}))
    end)

    assert {:ok, %{title: "Tidewater Bureau"}} =
             Relay.fetch_by_ref(ctx.config, {:tmdb, ctx.tmdb_id}, media_type: :tv_show)
  end

  test "a fetch without a type is still checked against the registry", ctx do
    ProviderIDRegistry.record_id_type({:tmdb, ctx.tmdb_id}, :tv_show)

    assert {:error, _} = Relay.fetch_by_ref(ctx.config, {:tmdb, ctx.tmdb_id}, [])
  end
end
