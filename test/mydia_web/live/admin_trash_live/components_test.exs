defmodule MydiaWeb.AdminTrashLive.ComponentsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias MydiaWeb.AdminTrashLive.Components

  # `Mydia.Library.create_scanned_media_file/1` enforces media_item_id XOR
  # episode_id (see `lib/mydia/media/README.md`), so a trashed row with
  # neither association is not constructible through the context. label_for/1
  # is exercised directly instead, against structs shaped the way an orphaned
  # row (one whose media item or episode has since been deleted) actually
  # renders: media_item and episode preloaded to nil rather than to a record.
  describe "label_for/1" do
    test "falls back to the relative path when there is no media item" do
      file = %MediaFile{media_item: nil, episode: nil, relative_path: "orphan/gone.mkv"}

      assert Components.label_for(file) == "orphan/gone.mkv"
    end

    test "falls back to a fixed label when there is neither a media item nor a path" do
      file = %MediaFile{media_item: nil, episode: nil, relative_path: nil}

      assert Components.label_for(file) == "Unknown file"
    end

    # An episode's media_files row carries episode_id with media_item_id
    # NULL; the show hangs off episode.media_item rather than off the file
    # directly (lib/mydia/media/README.md, "A TV media_file has
    # media_item_id NULL"). A movie fixture passes this function either way,
    # which is why matching media_item first shipped broken twice before, so
    # this case has to build the episode shape explicitly.
    test "prefers the show title and episode number when the file has an episode" do
      file = %MediaFile{
        media_item: nil,
        relative_path: "shows/nightfall.s02e04.mkv",
        episode: %Episode{
          media_item: %MediaItem{title: "Nightfall Harbor"},
          season_number: 2,
          episode_number: 4
        }
      }

      assert Components.label_for(file) == "Nightfall Harbor S02E04"
    end

    test "falls back to the relative path when the episode has no media item" do
      file = %MediaFile{
        media_item: nil,
        relative_path: "shows/nightfall.s02e04.mkv",
        episode: %Episode{media_item: nil, season_number: 2, episode_number: 4}
      }

      assert Components.label_for(file) == "shows/nightfall.s02e04.mkv"
    end
  end
end
