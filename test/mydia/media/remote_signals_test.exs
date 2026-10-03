defmodule Mydia.Media.RemoteSignalsTest do
  use ExUnit.Case, async: false

  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0]
  import Mydia.RelayStubs

  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, config: relay_config(bypass)}
  end

  test "looks up rating and category, then serves the cache", ctx do
    id = unique_provider_id()
    stub_tmdb_movie(ctx.bypass, id, certification: "PG", genres: ["Animation"], test_pid: self())
    on_exit(fn -> Cache.delete(RemoteSignals.cache_key({:tmdb, id}, :movie)) end)

    result = movie(id)
    assert %{{:movie, {:tmdb, ^id}} => signals} = RemoteSignals.fetch_many([result], ctx.config)
    assert signals == %RemoteSignals{content_rating: "PG", age: 8, category: "cartoon_movie"}

    assert_received {:relay_hit, _, ["release_dates"]}
    RemoteSignals.fetch_many([result], ctx.config)
    refute_received {:relay_hit, _, _}
  end

  test "an error is :error and is not cached", ctx do
    id = unique_provider_id()
    Bypass.stub(ctx.bypass, "GET", "/tmdb/movies/#{id}", &Plug.Conn.resp(&1, 500, "boom"))

    assert %{{:movie, {:tmdb, ^id}} => :error} = RemoteSignals.fetch_many([movie(id)], ctx.config)
    assert Cache.get(RemoteSignals.cache_key({:tmdb, id}, :movie)) == {:error, :not_found}
  end

  test "an empty list makes no requests", ctx do
    assert RemoteSignals.fetch_many([], ctx.config) == %{}
  end

  defp movie(id),
    do: %SearchResult{provider_id: to_string(id), provider: :tmdb, media_type: :movie, id: id}
end
