defmodule Mydia.Jobs.AiringEpisodeRefreshTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Jobs.AiringEpisodeRefresh

  @today ~D[2026-09-14]

  defp due_show(title) do
    item = media_item_fixture(%{type: "tv_show", title: title, year: 2025})

    episode_fixture(%{
      media_item_id: item.id,
      season_number: 1,
      episode_number: 8,
      title: "TBA ",
      air_date: Date.add(@today, 1)
    })

    item
  end

  describe "perform/1" do
    test "the first attempt snoozes for at most fifteen minutes" do
      assert {:snooze, seconds} = perform_job(AiringEpisodeRefresh, %{"scope" => "hot"})
      assert seconds >= 1
      assert seconds <= 900
    end

    test "a later attempt runs the pass" do
      assert :ok = perform_job(AiringEpisodeRefresh, %{"scope" => "all"}, attempt: 2)
    end

    test "an unknown scope is cancelled rather than retried" do
      assert {:cancel, _reason} =
               perform_job(AiringEpisodeRefresh, %{"scope" => "sometimes"}, attempt: 2)
    end
  end

  describe "run/3" do
    test "hands each due show the seasons to re-read" do
      item = due_show("Lantern Bay")
      test_pid = self()

      assert :ok =
               AiringEpisodeRefresh.run(:hot, @today, fn show, seasons ->
                 send(test_pid, {:refreshed, show.id, seasons})
                 {:ok, []}
               end)

      assert_received {:refreshed, id, [1]}
      assert id == item.id
    end

    test "one raising show does not stop the pass, and failures are reported once" do
      first = due_show("Harbor North")
      due_show("Harbor South")

      refresh = fn show, _seasons ->
        if show.id == first.id, do: raise("boom"), else: {:error, :relay_unavailable}
      end

      assert :ok = AiringEpisodeRefresh.run(:all, @today, refresh)

      assert [event] = Events.list_events(category: "system", type: "job.failed")
      assert event.metadata["job_name"] == "airing_episode_refresh"
      assert event.metadata["total"] == 2
      assert event.metadata["succeeded"] == 0
      assert event.metadata["failed"] == 2
    end

    test "records no failure event when every show succeeds" do
      due_show("Lantern Bay")

      assert :ok = AiringEpisodeRefresh.run(:all, @today, fn _show, _seasons -> {:ok, []} end)

      assert Events.list_events(category: "system", type: "job.failed") == []
    end
  end
end
