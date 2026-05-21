defmodule MydiaWeb.Schema.Resolvers.StreamingResolverTest do
  use Mydia.DataCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Streaming.Torrent.CandidateCache
  alias MydiaWeb.Schema.Resolvers.StreamingResolver

  setup do
    # CandidateCache is a global ETS-backed cache; isolate tests by wiping
    # it before each one. async: false above keeps tests from interleaving.
    CandidateCache.clear()
    :ok
  end

  describe "start_torrent_session/3 validation" do
    test "rejects requests that provide both tmdb_id and tvdb_id" do
      user = AccountsFixtures.user_fixture()

      # When both tmdb_id and tvdb_id are non-nil, the resolver leaves them
      # both populated (no NodeId.decode collapse), so validation must reject.
      assert {:error,
              "Exactly one of media_item_id, episode_id, tmdb_id, or tvdb_id must be provided"} =
               StreamingResolver.start_torrent_session(
                 %{},
                 %{
                   magnet_link: "magnet:?xt=urn:btih:test",
                   release_title: "Test Release",
                   tmdb_id: 1234,
                   tvdb_id: 5678
                 },
                 %{context: %{current_user: user}}
               )
    end

    test "rejects requests that provide no target ids" do
      user = AccountsFixtures.user_fixture()

      assert {:error, "Either media_item_id, episode_id, tmdb_id, or tvdb_id must be provided"} =
               StreamingResolver.start_torrent_session(
                 %{},
                 %{
                   magnet_link: "magnet:?xt=urn:btih:test",
                   release_title: "Test Release"
                 },
                 %{context: %{current_user: user}}
               )
    end

    test "rejects unauthenticated requests" do
      assert {:error, "Authentication required"} =
               StreamingResolver.start_torrent_session(
                 %{},
                 %{magnet_link: "magnet:?xt=urn:btih:test", release_title: "Test"},
                 %{context: %{}}
               )
    end

    test "rejects magnets not surfaced by torrentCandidates" do
      user = AccountsFixtures.user_fixture()
      media_item_id = Ecto.UUID.generate()

      # Cache is empty for this user; the resolver should refuse the magnet.
      assert {:error, message} =
               StreamingResolver.start_torrent_session(
                 %{},
                 %{
                   magnet_link: "magnet:?xt=urn:btih:somehash",
                   release_title: "Untrusted",
                   media_item_id: media_item_id
                 },
                 %{context: %{current_user: user}}
               )

      assert message =~ "torrentCandidates"
    end
  end

  describe "end_torrent_session/3 ownership" do
    test "rejects unauthenticated requests" do
      assert {:error, "Authentication required"} =
               StreamingResolver.end_torrent_session(
                 %{},
                 %{session_id: Ecto.UUID.generate()},
                 %{context: %{}}
               )
    end

    test "returns ok idempotently when the session does not exist" do
      user = AccountsFixtures.user_fixture()

      assert {:ok, true} =
               StreamingResolver.end_torrent_session(
                 %{},
                 %{session_id: Ecto.UUID.generate()},
                 %{context: %{current_user: user}}
               )
    end
  end
end
