defmodule Mydia.PlaybackUserHistoryTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Playback
  alias Mydia.Repo

  defp watch(user, content, at) do
    {:ok, p} =
      Playback.save_progress(user.id, content, %{position_seconds: 60, duration_seconds: 600})

    p |> Ecto.Changeset.change(last_watched_at: at) |> Repo.update!()
  end

  defp at(offset_days),
    do: DateTime.utc_now() |> DateTime.add(-offset_days * 86_400) |> DateTime.truncate(:second)

  test "newest first, with show preloaded through the episode" do
    user = user_fixture()
    old = media_item_fixture(%{type: "movie", title: "Pale Orchard"})
    show = media_item_fixture(%{type: "tv_show", title: "Signal Harbor"})
    ep = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 3})

    watch(user, [media_item_id: old.id], at(5))
    watch(user, [episode_id: ep.id], at(1))

    assert [first, second] = Playback.list_user_history(user.id)
    assert first.episode.media_item.title == "Signal Harbor"
    assert second.media_item.title == "Pale Orchard"
  end

  test "rows with no last_watched_at are excluded" do
    user = user_fixture()
    movie = media_item_fixture(%{type: "movie", title: "Quiet Meridian"})
    watch(user, [media_item_id: movie.id], nil)

    assert Playback.list_user_history(user.id) == []
  end

  test ":since keeps only watches at or after the bound" do
    user = user_fixture()
    a = media_item_fixture(%{type: "movie", title: "Glass Tundra"})
    b = media_item_fixture(%{type: "movie", title: "Copper Lagoon"})
    watch(user, [media_item_id: a.id], at(30))
    watch(user, [media_item_id: b.id], at(2))

    assert [row] = Playback.list_user_history(user.id, since: at(7))
    assert row.media_item_id == b.id
  end

  test "only the given user's rows, capped by :limit" do
    user = user_fixture()
    other = user_fixture()

    for n <- 1..3 do
      m = media_item_fixture(%{type: "movie", title: "Lumen Drift #{n}"})
      watch(user, [media_item_id: m.id], at(n))
    end

    m = media_item_fixture(%{type: "movie", title: "Foreign Shore"})
    watch(other, [media_item_id: m.id], at(0))

    rows = Playback.list_user_history(user.id, limit: 2)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.user_id == user.id))
  end
end
