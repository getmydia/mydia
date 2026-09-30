defmodule Mydia.Playback.ProgressOriginTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Playback

  setup do
    {:ok, user: user_fixture(), movie: media_item_fixture(%{title: "The Glass Orchard"})}
  end

  test "save_progress records the write origin", %{user: user, movie: movie} do
    {:ok, p} =
      Playback.save_progress(
        user.id,
        [media_item_id: movie.id],
        %{position_seconds: 60, duration_seconds: 600},
        origin: "plugin:plex:abc"
      )

    assert p.last_write_origin == "plugin:plex:abc"
  end

  test "the default origin is player", %{user: user, movie: movie} do
    {:ok, p} =
      Playback.save_progress(user.id, [media_item_id: movie.id], %{
        position_seconds: 60,
        duration_seconds: 600
      })

    assert p.last_write_origin == "player"
  end

  test "mark_watched overwrites the origin", %{user: user, movie: movie} do
    {:ok, _} =
      Playback.save_progress(user.id, [media_item_id: movie.id], %{
        position_seconds: 60,
        duration_seconds: 600
      })

    {:ok, p} = Playback.mark_watched(user.id, [media_item_id: movie.id], origin: "sync:jellyfin")
    assert p.last_write_origin == "sync:jellyfin"
  end
end
