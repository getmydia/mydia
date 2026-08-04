defmodule Mydia.Events.PresentationTest do
  use ExUnit.Case, async: true

  alias Mydia.Events.Event
  alias Mydia.Events.Presentation

  defp event(attrs) do
    struct!(%Event{severity: :info, metadata: %{}}, attrs)
  end

  describe "known_types/0" do
    test "covers all 32 event types" do
      assert length(Presentation.known_types()) == 32
    end

    test "has no duplicate entries" do
      types = Presentation.known_types()
      assert types == Enum.uniq(types)
    end

    test "includes the type that triggered this work" do
      assert "download.stalled" in Presentation.known_types()
    end
  end

  describe "feed_hidden_types/0" do
    test "hides the per-request plugin audit trail" do
      assert Presentation.feed_hidden_types() == ["plugin.http_request"]
    end
  end

  describe "for_event/1 registered types" do
    test "every registered type resolves to a usable title and icon" do
      for type <- Presentation.known_types() do
        presentation = Presentation.for_event(event(type: type))

        assert is_binary(presentation.title) and presentation.title != "",
               "#{type} has no title"

        assert String.starts_with?(presentation.icon, "hero-"),
               "#{type} has icon #{inspect(presentation.icon)}"

        assert is_binary(presentation.color) and presentation.color != "",
               "#{type} resolved to no color"
      end
    end

    test "no title leaks a raw event key" do
      for type <- Presentation.known_types() do
        presentation = Presentation.for_event(event(type: type))
        refute presentation.title =~ ".", "#{type} title looks like a raw key"
      end
    end
  end

  describe "for_event/1 unknown types" do
    test "humanizes the raw key into a readable title" do
      presentation = Presentation.for_event(event(type: "legacy.retired_thing"))
      assert presentation.title == "Legacy retired thing"
    end

    test "derives icon and color from severity" do
      assert %{icon: "hero-exclamation-circle", color: "text-error"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :error))

      assert %{icon: "hero-exclamation-triangle", color: "text-warning"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :warning))

      assert %{icon: "hero-information-circle", color: "text-info"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :info))
    end
  end

  describe "detail/1 fallback" do
    test "falls back to the metadata title" do
      assert Presentation.detail(event(type: "legacy.gone", metadata: %{"title" => "Arrival"})) ==
               "Arrival"
    end

    test "falls back to the metadata description" do
      assert Presentation.detail(
               event(type: "legacy.gone", metadata: %{"description" => "something happened"})
             ) == "something happened"
    end

    test "returns nil when metadata carries nothing usable" do
      assert Presentation.detail(event(type: "legacy.gone", metadata: %{})) == nil
    end
  end

  describe "detail/1 media_item.*" do
    test "added names the item and its media type" do
      assert Presentation.detail(
               event(
                 type: "media_item.added",
                 metadata: %{"title" => "Arrival", "media_type" => "movie"}
               )
             ) == "Arrival (movie)"
    end

    test "added treats anything other than a movie as a TV show" do
      assert Presentation.detail(
               event(
                 type: "media_item.added",
                 metadata: %{"title" => "Severance", "media_type" => "tv_show"}
               )
             ) == "Severance (TV show)"
    end

    test "updated carries the reason and the change summary" do
      detail =
        Presentation.detail(
          event(
            type: "media_item.updated",
            metadata: %{
              "title" => "Arrival",
              "reason" => "Metadata refresh",
              "changes" => %{"title" => %{"old" => "a", "new" => "b"}}
            }
          )
        )

      assert detail == "Arrival, metadata refresh (title)"
    end

    test "updated degrades to the title alone" do
      assert Presentation.detail(
               event(type: "media_item.updated", metadata: %{"title" => "Arrival"})
             ) ==
               "Arrival"
    end

    test "removed is just the title" do
      assert Presentation.detail(
               event(type: "media_item.removed", metadata: %{"title" => "Arrival"})
             ) ==
               "Arrival"
    end

    test "monitoring_changed states the new state" do
      assert Presentation.detail(
               event(
                 type: "media_item.monitoring_changed",
                 metadata: %{"title" => "Severance", "monitored" => true}
               )
             ) == "Severance, monitoring enabled"

      assert Presentation.detail(
               event(
                 type: "media_item.monitoring_changed",
                 metadata: %{"title" => "Severance", "monitored" => false}
               )
             ) == "Severance, monitoring disabled"
    end

    test "episodes_refreshed pluralizes the count" do
      assert Presentation.detail(
               event(
                 type: "media_item.episodes_refreshed",
                 metadata: %{"title" => "Severance", "episode_count" => 1}
               )
             ) == "Severance, 1 episode"

      assert Presentation.detail(
               event(
                 type: "media_item.episodes_refreshed",
                 metadata: %{"title" => "Severance", "episode_count" => 9}
               )
             ) == "Severance, 9 episodes"
    end
  end

  describe "detail/1 media_file.*" do
    test "imported prefers the resolution as the descriptor" do
      assert Presentation.detail(
               event(
                 type: "media_file.imported",
                 metadata: %{
                   "media_title" => "Arrival",
                   "file_path" => "Arrival.mkv",
                   "resolution" => "2160p"
                 }
               )
             ) == "Arrival 2160p"
    end

    test "imported falls back to the file path" do
      assert Presentation.detail(
               event(
                 type: "media_file.imported",
                 metadata: %{"media_title" => "Arrival", "file_path" => "Arrival.mkv"}
               )
             ) == "Arrival Arrival.mkv"
    end

    test "imported ignores an unknown file path" do
      assert Presentation.detail(
               event(
                 type: "media_file.imported",
                 metadata: %{"media_title" => "Arrival", "file_path" => "unknown"}
               )
             ) == "Arrival"
    end

    test "upgraded shows the resolution jump and score delta" do
      assert Presentation.detail(
               event(
                 type: "media_file.upgraded",
                 metadata: %{
                   "title" => "Arrival",
                   "old_resolution" => "1080p",
                   "new_resolution" => "2160p",
                   "delta" => 35
                 }
               )
             ) == "Arrival, 1080p to 2160p (score +35)"
    end

    test "upgrade_rejected says what was kept and whether the release was blacklisted" do
      assert Presentation.detail(
               event(
                 type: "media_file.upgrade_rejected",
                 metadata: %{
                   "title" => "Arrival",
                   "old_resolution" => "2160p",
                   "new_resolution" => "1080p",
                   "blacklisted" => true
                 }
               )
             ) == "Arrival, kept 2160p over 1080p, release blacklisted"
    end

    test "upgrade_rejected omits the blacklist note for season packs" do
      assert Presentation.detail(
               event(
                 type: "media_file.upgrade_rejected",
                 metadata: %{
                   "title" => "Severance",
                   "old_resolution" => "2160p",
                   "new_resolution" => "1080p",
                   "blacklisted" => false
                 }
               )
             ) == "Severance, kept 2160p over 1080p"
    end
  end

  describe "detail/1 download.*" do
    test "stalled carries the stall message" do
      assert Presentation.detail(
               event(
                 type: "download.stalled",
                 severity: :warning,
                 metadata: %{"title" => "Arrival 2160p", "message" => "no progress for 2h"}
               )
             ) == "Arrival 2160p (no progress for 2h)"
    end

    test "stalled degrades to the title when no message is recorded" do
      assert Presentation.detail(
               event(type: "download.stalled", metadata: %{"title" => "Arrival 2160p"})
             ) == "Arrival 2160p"
    end

    test "the plain lifecycle events are just the title" do
      for type <- ~w(download.initiated download.completed download.cancelled
                     download.paused download.resumed download.unstalled) do
        assert Presentation.detail(event(type: type, metadata: %{"title" => "Arrival"})) ==
                 "Arrival",
               "#{type} did not render its title"
      end
    end

    test "cleared names the download client" do
      assert Presentation.detail(
               event(
                 type: "download.cleared",
                 metadata: %{"title" => "Arrival", "download_client" => "transmission"}
               )
             ) == "Arrival (transmission)"
    end

    test "failed carries the selected release and the error" do
      assert Presentation.detail(
               event(
                 type: "download.failed",
                 severity: :error,
                 metadata: %{
                   "title" => "Severance",
                   "season_number" => 1,
                   "episode_number" => 2,
                   "selected_release" => "Severance.S01E02.2160p",
                   "error_message" => "no seeds"
                 }
               )
             ) == "Severance S01E02: Severance.S01E02.2160p (no seeds)"
    end

    test "failed without a selected release still reports the error" do
      assert Presentation.detail(
               event(
                 type: "download.failed",
                 metadata: %{"title" => "Arrival", "error_message" => "disk full"}
               )
             ) == "Arrival (disk full)"
    end
  end

  describe "detail/1 job.*" do
    test "executed reports throughput when the metadata has it" do
      assert Presentation.detail(
               event(
                 type: "job.executed",
                 metadata: %{
                   "job_name" => "Library Scan",
                   "items_processed" => 42,
                   "duration_ms" => 1200
                 }
               )
             ) == "Library Scan, processed 42 items, in 1200ms"
    end

    test "executed degrades to the job name" do
      assert Presentation.detail(
               event(type: "job.executed", metadata: %{"job_name" => "Library Scan"})
             ) ==
               "Library Scan"
    end

    test "failed carries the error" do
      assert Presentation.detail(
               event(
                 type: "job.failed",
                 severity: :error,
                 metadata: %{"job_name" => "Metadata Sync", "error_message" => "timeout"}
               )
             ) == "Metadata Sync (timeout)"
    end
  end

  describe "detail/1 search.*" do
    test "started names the subject with its episode" do
      assert Presentation.detail(
               event(
                 type: "search.started",
                 metadata: %{"title" => "Severance", "season_number" => 1, "episode_number" => 2}
               )
             ) == "Severance S01E02"
    end

    test "completed reports the result count and selection" do
      assert Presentation.detail(
               event(
                 type: "search.completed",
                 metadata: %{
                   "title" => "Arrival",
                   "results_count" => 12,
                   "selected_release" => "Arrival.2160p"
                 }
               )
             ) == "Arrival, 12 results, selected Arrival.2160p"
    end

    test "filtered_out reports how many were rejected" do
      assert Presentation.detail(
               event(
                 type: "search.filtered_out",
                 metadata: %{"title" => "Arrival", "results_count" => 7}
               )
             ) == "Arrival, 7 rejected"
    end

    test "error carries the error message" do
      assert Presentation.detail(
               event(
                 type: "search.error",
                 severity: :error,
                 metadata: %{"title" => "Arrival", "error_message" => "indexer down"}
               )
             ) == "Arrival (indexer down)"
    end

    test "backoff_applied spells out reason, attempt, and next eligible time" do
      next = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.to_iso8601()

      detail =
        Presentation.detail(
          event(
            type: "search.backoff_applied",
            severity: :warning,
            metadata: %{
              "title" => "Severance",
              "season_number" => 1,
              "episode_number" => 2,
              "episode_id" => "abc",
              "reason" => "no_results",
              "failure_count" => 3,
              "next_eligible_at" => next
            }
          )
        )

      assert detail =~ "Severance S01E02 (episode)"
      assert detail =~ "no results found"
      assert detail =~ "attempt #3"
      assert detail =~ "next search in "
      assert detail =~ "hours"
    end

    test "backoff_reset reports how many attempts it took" do
      assert Presentation.detail(
               event(
                 type: "search.backoff_reset",
                 metadata: %{"title" => "Arrival", "previous_failure_count" => 4}
               )
             ) == "Arrival (show), backoff cleared after 4 failed attempts"
    end
  end

  describe "detail/1 plugin.*" do
    test "http_request summarizes the call" do
      assert Presentation.detail(
               event(
                 type: "plugin.http_request",
                 metadata: %{
                   "slug" => "tmdb-art",
                   "method" => "GET",
                   "host" => "api.themoviedb.org",
                   "status" => 200,
                   "duration_ms" => 84
                 }
               )
             ) == "tmdb-art: GET api.themoviedb.org (200, 84ms)"
    end

    test "http_request survives a failed call with no status" do
      assert Presentation.detail(
               event(
                 type: "plugin.http_request",
                 severity: :error,
                 metadata: %{
                   "slug" => "tmdb-art",
                   "method" => "GET",
                   "host" => "api.themoviedb.org",
                   "duration_ms" => 5000
                 }
               )
             ) == "tmdb-art: GET api.themoviedb.org (5000ms)"
    end

    test "update_available names both versions" do
      assert Presentation.detail(
               event(
                 type: "plugin.update_available",
                 metadata: %{
                   "slug" => "tmdb-art",
                   "current_version" => "1.0.0",
                   "latest_version" => "1.2.0"
                 }
               )
             ) == "tmdb-art 1.0.0 to 1.2.0"
    end
  end

  describe "detail/1 playback.*" do
    test "finished reports progress and origin" do
      assert Presentation.detail(
               event(
                 type: "playback.finished",
                 metadata: %{"completion_percentage" => 98, "origin" => "player"}
               )
             ) == "98% watched, from player"
    end

    test "started with only an origin reports the origin" do
      assert Presentation.detail(
               event(type: "playback.started", metadata: %{"origin" => "player"})
             ) ==
               "from player"
    end

    test "returns nil when playback metadata carries neither" do
      assert Presentation.detail(event(type: "playback.paused", metadata: %{})) == nil
    end
  end

  describe "detail/1 totality" do
    test "never raises for any registered type, with metadata present or absent" do
      for type <- Presentation.known_types() do
        assert Presentation.detail(event(type: type, metadata: %{})) == nil or
                 is_binary(Presentation.detail(event(type: type, metadata: %{})))

        detail = Presentation.detail(event(type: type, metadata: %{"title" => "Fixture"}))
        assert is_nil(detail) or is_binary(detail)
      end
    end
  end

  describe "registry coverage backstop" do
    test "every event type recorded in lib/ is registered" do
      {output, status} =
        System.cmd("grep", ["-rhoE", ~S{type: "[a-z_]+\.[a-z_]+"}, "lib/"])

      assert status == 0, "grep exited #{status}, expected 0 (a match was found)"

      recorded =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.replace(~s{type: "}, "") |> String.replace(~s{"}, "")))
        |> Enum.uniq()

      assert recorded != [],
             "grep found no event types in lib/; the backstop is broken, not the registry"

      unregistered = recorded -- Presentation.known_types()

      assert unregistered == [],
             "these event types are recorded in lib/ but not registered in Presentation: " <>
               inspect(unregistered)
    end
  end
end
