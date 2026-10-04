defmodule Mydia.Jobs.SearchDeferralTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Jobs.{MovieSearch, SearchDeferral}

  test "schedules the re-check a minute after the delay ends and records the event" do
    movie = media_item_fixture(%{type: "movie", title: "Glass Harbor", year: 2031})
    until = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert :ok =
             SearchDeferral.defer(
               Mydia.Jobs.MovieSearch,
               %{"mode" => "specific", "media_item_id" => movie.id, "recheck" => true},
               until,
               movie,
               %{"selected_release" => "Glass.Harbor.2031.720p"}
             )

    assert [job] =
             Mydia.Repo.all(Oban.Job) |> Enum.filter(&(&1.worker == "Mydia.Jobs.MovieSearch"))

    assert job.args == %{
             "mode" => "specific",
             "media_item_id" => movie.id,
             "recheck" => true
           }

    assert job.state == "scheduled"
    assert DateTime.diff(job.scheduled_at, until) == 60

    Process.sleep(100)
    assert [event] = Mydia.Events.list_events(type: "search.deferred")
    assert event.metadata["grab_after"] == DateTime.to_iso8601(until)
  end

  describe "pending_rechecks/1" do
    test "returns the args of scheduled re-checks only" do
      scheduled_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      recheck = %{"mode" => "specific", "media_item_id" => "a", "recheck" => true}
      unmarked = %{"mode" => "specific", "media_item_id" => "b"}
      running = %{"mode" => "specific", "media_item_id" => "c", "recheck" => true}

      {:ok, _} =
        recheck |> MovieSearch.new(scheduled_at: scheduled_at) |> Mydia.Repo.insert()

      {:ok, _} =
        unmarked |> MovieSearch.new(scheduled_at: scheduled_at) |> Mydia.Repo.insert()

      {:ok, _} =
        running
        |> MovieSearch.new()
        |> Ecto.Changeset.put_change(:state, "executing")
        |> Mydia.Repo.insert()

      assert SearchDeferral.pending_rechecks(MovieSearch) == [recheck]
      assert SearchDeferral.pending_rechecks(Mydia.Jobs.TVShowSearch) == []
    end
  end
end
