defmodule Mydia.Metadata.Provider.RelayRatingAppendTest do
  use ExUnit.Case, async: true

  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0]
  import Mydia.RelayStubs

  alias Mydia.Metadata.Provider.Relay

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, config: relay_config(bypass)}
  end

  for {label, opts} <- [
        {"no append list", []},
        {"a custom append list", [append_to_response: ["credits"]]},
        {"an empty append list", [append_to_response: []]}
      ] do
    test "a movie fetch with #{label} carries the certification", ctx do
      id = unique_provider_id()
      stub_tmdb_movie(ctx.bypass, id, certification: "PG-13", test_pid: self())

      assert {:ok, md} =
               Relay.fetch_by_ref(ctx.config, {:tmdb, id}, [media_type: :movie] ++ unquote(opts))

      assert md.content_rating == "PG-13"
      assert_received {:relay_hit, _, append}
      assert "release_dates" in append
      refute "content_ratings" in append
    end

    test "a tv fetch with #{label} carries the certification", ctx do
      id = unique_provider_id()
      stub_tmdb_tv(ctx.bypass, id, certification: "TV-14", test_pid: self())

      assert {:ok, md} =
               Relay.fetch_by_ref(
                 ctx.config,
                 {:tmdb, id},
                 [media_type: :tv_show] ++ unquote(opts)
               )

      assert md.content_rating == "TV-14"
      assert_received {:relay_hit, _, append}
      assert "content_ratings" in append
      refute "release_dates" in append
    end
  end

  test "a caller's own resources are kept alongside the rating", ctx do
    id = unique_provider_id()
    stub_tmdb_movie(ctx.bypass, id, certification: "R", test_pid: self())

    {:ok, _} =
      Relay.fetch_by_ref(ctx.config, {:tmdb, id},
        media_type: :movie,
        append_to_response: ["credits", "videos"]
      )

    assert_received {:relay_hit, _, append}
    assert Enum.sort(append) == ["credits", "release_dates", "videos"]
  end

  test "the rating resource is never sent twice", ctx do
    id = unique_provider_id()
    stub_tmdb_movie(ctx.bypass, id, certification: "R", test_pid: self())

    {:ok, _} =
      Relay.fetch_by_ref(ctx.config, {:tmdb, id},
        media_type: :movie,
        append_to_response: ["release_dates"]
      )

    assert_received {:relay_hit, _, ["release_dates"]}
  end
end
