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
end
