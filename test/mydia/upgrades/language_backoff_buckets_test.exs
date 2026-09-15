defmodule Mydia.Upgrades.LanguageBackoffBucketsTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory

  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Search

  test "the language buckets are valid backoff resource types" do
    show = insert(:tv_show, title: "Kaiju Garden")
    episode = insert(:episode, media_item: show)

    assert {:ok, _} = Search.record_failure("movie_language_upgrade", show.id, "no_results")
    assert {:ok, _} = Search.record_failure("episode_language_upgrade", episode.id, "no_results")

    assert {:ok, _} =
             Search.record_failure("season_language_upgrade", show.id, "no_results",
               season_number: 1
             )
  end

  test "media items and episodes carry a language check stamp" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    show = insert(:tv_show, title: "Kaiju Garden")
    episode = insert(:episode, media_item: show)

    show |> Ecto.Changeset.change(last_language_check_at: now) |> Repo.update!()
    episode |> Ecto.Changeset.change(last_language_check_at: now) |> Repo.update!()

    assert Repo.get!(MediaItem, show.id).last_language_check_at == now
    assert Repo.get!(Episode, episode.id).last_language_check_at == now
  end
end
