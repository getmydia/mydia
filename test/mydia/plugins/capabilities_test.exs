defmodule Mydia.Plugins.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Capabilities

  describe "ungranted/2 class-level comparison" do
    test "an unchanged set is fully covered" do
      set = %{"events:subscribe" => ["media_item.added"], "net:http" => ["discord.com"]}

      assert Capabilities.ungranted(set, set) == %{}
      assert Capabilities.covered?(set, set)
    end

    test "a wholly new class is reported with its full payload" do
      requested = %{"events:subscribe" => ["media_item.added"], "data:read" => ["media_item"]}
      granted = %{"events:subscribe" => ["media_item.added"]}

      assert Capabilities.ungranted(requested, granted) == %{"data:read" => ["media_item"]}
      refute Capabilities.covered?(requested, granted)
    end

    test "a new flag capability is reported even though it carries no values" do
      requested = %{"events:subscribe" => ["media_item.added"], "state:kv" => []}
      granted = %{"events:subscribe" => ["media_item.added"]}

      assert Capabilities.ungranted(requested, granted) == %{"state:kv" => []}
    end

    test "a granted flag capability is covered" do
      set = %{"state:kv" => [], "schedule:interval" => []}

      assert Capabilities.ungranted(set, set) == %{}
    end

    test "capabilities granted but no longer requested are not reported" do
      requested = %{"events:subscribe" => ["media_item.added"]}
      granted = %{"events:subscribe" => ["media_item.added"], "net:http" => ["discord.com"]}

      assert Capabilities.ungranted(requested, granted) == %{}
    end

    test "an empty request is covered by any grant" do
      assert Capabilities.ungranted(%{}, %{"net:http" => ["discord.com"]}) == %{}
    end

    test "nothing is covered by an empty grant" do
      requested = %{"events:subscribe" => ["media_item.added"]}

      assert Capabilities.ungranted(requested, %{}) == requested
    end
  end

  describe "ungranted/2 payload-level comparison" do
    test "a new event on an already-granted events:subscribe is reported" do
      requested = %{"events:subscribe" => ["media_item.added", "download.completed"]}
      granted = %{"events:subscribe" => ["media_item.added"]}

      assert Capabilities.ungranted(requested, granted) == %{
               "events:subscribe" => ["download.completed"]
             }
    end

    test "a new host on an already-granted net:http is reported" do
      requested = %{"net:http" => ["discord.com", "api.example.com"]}
      granted = %{"net:http" => ["discord.com"]}

      assert Capabilities.ungranted(requested, granted) == %{"net:http" => ["api.example.com"]}
    end

    test "only the new values are reported, not the whole payload" do
      requested = %{"data:read" => ["media_item", "playback_progress"]}
      granted = %{"data:read" => ["media_item"]}

      assert Capabilities.ungranted(requested, granted) == %{"data:read" => ["playback_progress"]}
    end

    test "an operator-widened grant (a host-granting setting) still covers the manifest" do
      # The stored grant holds the manifest's static host plus the host derived
      # from a configured URL; the manifest itself never mentions the latter.
      requested = %{"net:http" => ["discord.com"]}
      granted = %{"net:http" => ["discord.com", "ntfy.example.com"]}

      assert Capabilities.ungranted(requested, granted) == %{}
    end

    test "a narrowed payload is not reported" do
      requested = %{"net:http" => ["discord.com"]}
      granted = %{"net:http" => ["discord.com", "old.example.com"]}

      assert Capabilities.ungranted(requested, granted) == %{}
    end

    test "an opaque payload that changed counts as a new request (fail-closed)" do
      requested = %{"schedule:interval" => %{"interval_minutes" => 5}}
      granted = %{"schedule:interval" => %{"interval_minutes" => 30}}

      assert Capabilities.ungranted(requested, granted) == %{
               "schedule:interval" => [%{"interval_minutes" => 5}]
             }
    end

    test "an identical opaque payload is covered" do
      set = %{"schedule:interval" => %{"interval_minutes" => 30}}

      assert Capabilities.ungranted(set, set) == %{}
    end
  end

  describe "summary/1" do
    test "renders classes and values compactly, sorted" do
      set = %{"net:http" => ["api.example.com"], "data:read" => ["media_item"]}

      assert Capabilities.summary(set) == "data:read [media_item], net:http [api.example.com]"
    end

    test "renders a flag capability as the bare class" do
      assert Capabilities.summary(%{"state:kv" => []}) == "state:kv"
    end

    test "renders an empty set" do
      assert Capabilities.summary(%{}) == "(none)"
    end
  end
end
