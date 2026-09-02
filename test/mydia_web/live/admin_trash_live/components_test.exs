defmodule MydiaWeb.AdminTrashLive.ComponentsTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
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
  end
end
