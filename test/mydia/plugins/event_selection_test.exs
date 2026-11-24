defmodule Mydia.Plugins.EventSelectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.EventSelection
  alias Mydia.Plugins.Plugin

  @all ["media_request.created", "media_request.approved", "download.completed"]

  defp plugin(selection \\ %{key: "events", default: ["media_request.created"]}),
    do: %Plugin{events: @all, event_selection: selection}

  test "a saved list is used" do
    assert EventSelection.selected(plugin(), %{"events" => ["media_request.approved"]}) ==
             ["media_request.approved"]
  end

  test "absent key falls back to the default" do
    assert EventSelection.selected(plugin(), %{}) == ["media_request.created"]
  end

  test "absent key and nil default means everything" do
    assert EventSelection.selected(plugin(%{key: "events", default: nil}), %{}) == @all
  end

  test "a nil value is treated like a missing key" do
    assert EventSelection.selected(plugin(), %{"events" => nil}) == ["media_request.created"]

    assert EventSelection.selected(plugin(%{key: "events", default: nil}), %{"events" => nil}) ==
             @all
  end

  test "an empty list selects nothing" do
    assert EventSelection.selected(plugin(), %{"events" => []}) == []
  end

  test "a comma separated string is parsed" do
    assert EventSelection.selected(plugin(), %{
             "events" => "media_request.approved, download.completed"
           }) == ["media_request.approved", "download.completed"]
  end

  test "events the plugin does not subscribe to are dropped" do
    assert EventSelection.selected(plugin(), %{
             "events" => ["media_request.approved", "not.subscribed"]
           }) == ["media_request.approved"]
  end

  test "no events field means everything regardless of settings" do
    assert EventSelection.selected(plugin(nil), %{"events" => []}) == @all
  end

  test "wants?/3 agrees with selected/2" do
    settings = %{"events" => ["media_request.approved"]}

    for e <- @all do
      assert EventSelection.wants?(plugin(), settings, e) ==
               e in EventSelection.selected(plugin(), settings)
    end
  end

  describe "seed/2" do
    @manifest %{
      "capabilities" => %{"events:subscribe" => @all},
      "settings_schema" => [%{"key" => "events", "type" => "events"}]
    }

    test "adds the full list when the key is absent" do
      assert EventSelection.seed(@manifest, %{"a" => 1}) == %{"a" => 1, "events" => @all}
    end

    test "leaves an empty or existing list alone" do
      assert EventSelection.seed(@manifest, %{"events" => []}) == %{"events" => []}

      assert EventSelection.seed(@manifest, %{"events" => ["download.completed"]}) ==
               %{"events" => ["download.completed"]}
    end

    test "no-op without an events field" do
      manifest = %{"capabilities" => %{"events:subscribe" => @all}, "settings_schema" => []}
      assert EventSelection.seed(manifest, %{"a" => 1}) == %{"a" => 1}
      assert EventSelection.seed(%{}, %{"a" => 1}) == %{"a" => 1}
    end
  end
end
