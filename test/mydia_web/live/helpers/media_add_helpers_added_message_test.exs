defmodule MydiaWeb.Live.Helpers.MediaAddHelpersAddedMessageTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  test "tv shows mention the background episode fetch" do
    assert MediaAddHelpers.added_message(%{type: "tv_show", title: "The Slow Lantern"}) ==
             "The Slow Lantern has been added. Episodes are being fetched in the background."
  end

  test "movies keep the plain message" do
    assert MediaAddHelpers.added_message(%{type: "movie", title: "Quiet Harbor"}) ==
             "Quiet Harbor has been added to your library"
  end
end
