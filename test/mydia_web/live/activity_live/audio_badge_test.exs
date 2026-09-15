defmodule MydiaWeb.ActivityLive.AudioBadgeTest do
  # Mounts a LiveView against inserted rows, so it must not be async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Events

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "search results show each release's audio languages", %{conn: conn} do
    {:ok, _event} =
      Events.create_event(%{
        category: "search",
        type: "search.completed",
        actor_type: :job,
        actor_id: "tv_show_search",
        metadata: %{
          "title" => "Kaiju Garden",
          "query" => "Kaiju Garden S02",
          "results_count" => 2,
          "selected_release" => "[BlackRabbit] Kaiju Garden - S02 [Dual Audio]",
          "score" => 69.9,
          "breakdown" => %{"language_rank" => 0, "audio_languages" => ["en", "ja"]},
          "audio_preference" => ["en"],
          "audio_preference_source" => "show",
          "all_results" => %{
            "total_results" => 2,
            "rejection_counts" => %{},
            "results" => [
              %{
                "title" => "[BlackRabbit] Kaiju Garden - S02 [Dual Audio]",
                "score" => 69.9,
                "seeders" => 25,
                "status" => "accepted",
                "audio_languages" => ["en", "ja"],
                "audio_assumed" => false,
                "language_rank" => 0
              },
              %{
                "title" => "Kaiju.Garden.S02.1080p.CR.WEB-DL-VARYG",
                "score" => 50.6,
                "seeders" => 16,
                "status" => "accepted",
                "audio_languages" => ["ja"],
                "audio_assumed" => true,
                "language_rank" => 1
              }
            ]
          }
        }
      })

    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "[data-test='audio-badge']", "EN+JA")
    assert has_element?(view, "[data-test='audio-badge']", "JA (assumed)")
  end
end
