defmodule MydiaWeb.MediaLive.DiskRemovalFlashTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.DiskRemoval
  alias MydiaWeb.MediaLive.DiskRemovalFlash

  describe "for_item/3" do
    test "removing from the library only" do
      assert DiskRemovalFlash.for_item("Harbor Lights", false, %DiskRemoval{}) ==
               {:info, "Harbor Lights removed from library (files preserved)"}
    end

    test "a clean delete from disk" do
      assert DiskRemovalFlash.for_item("Harbor Lights", true, %DiskRemoval{}) ==
               {:info, "Harbor Lights deleted from disk."}
    end

    test "a folder kept because it holds other media is info, and named" do
      removal = %DiskRemoval{folders_kept: [{"/lib/Shared Reels", {:blocked, [{:video, "x"}]}}]}

      assert DiskRemovalFlash.for_item("Reel One", true, removal) ==
               {:info,
                "Reel One deleted from disk. Kept /lib/Shared Reels because it holds other media."}
    end

    test "files that could not be deleted are an error" do
      assert {:error, message} =
               DiskRemovalFlash.for_item("Harbor Lights", true, %DiskRemoval{files_failed: 2})

      assert message =~ "2 files could not be deleted from disk"
    end

    test "a folder rm_rf could not finish is an error" do
      removal = %DiskRemoval{folders_kept: [{"/lib/Locked Reel", {:error, :eacces}}]}

      assert DiskRemovalFlash.for_item("Locked Reel", true, removal) ==
               {:error,
                "Locked Reel deleted from disk. Couldn't remove /lib/Locked Reel (eacces)."}
    end
  end

  describe "for_items/3" do
    test "a clean bulk delete" do
      assert DiskRemovalFlash.for_items(2, true, %DiskRemoval{}) ==
               {:info, "2 items deleted from disk."}
    end

    test "names at most three kept folders" do
      kept = for n <- 1..4, do: {"/lib/F#{n}", {:blocked, [{:video, "x"}]}}

      assert DiskRemovalFlash.for_items(5, true, %DiskRemoval{folders_kept: kept}) ==
               {:info,
                "5 items deleted from disk. Kept 4 folders that hold other media: " <>
                  "/lib/F1, /lib/F2, /lib/F3 and 1 more."}
    end

    test "removing from the library only" do
      assert DiskRemovalFlash.for_items(1, false, %DiskRemoval{}) ==
               {:info, "1 item removed from library (files preserved)"}
    end
  end
end
