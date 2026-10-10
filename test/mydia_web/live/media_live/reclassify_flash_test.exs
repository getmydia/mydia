defmodule MydiaWeb.MediaLive.Index.ReclassifyFlashTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Index.ReclassifyFlash

  test "a single skipped item takes the singular verb" do
    assert ReclassifyFlash.message(%{updated: 0, skipped: 1}) ==
             "No changes - 1 item has category override"
  end

  test "several skipped items take the plural verb" do
    assert ReclassifyFlash.message(%{updated: 0, skipped: 2}) ==
             "No changes - 2 items have category override"
  end
end
