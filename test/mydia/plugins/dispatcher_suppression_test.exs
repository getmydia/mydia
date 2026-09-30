defmodule Mydia.Plugins.DispatcherSuppressionTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Dispatcher

  test "suppresses the slug-only and the instance-qualified origin" do
    assert Dispatcher.suppressed?("plugin:plex", "plex")
    assert Dispatcher.suppressed?("plugin:plex:0b7e", "plex")
  end

  test "does not suppress a different plugin whose slug shares a prefix" do
    refute Dispatcher.suppressed?("plugin:plex_extra", "plex")
    refute Dispatcher.suppressed?("plugin:plex_extra:0b7e", "plex")
  end

  test "does not suppress players, sync providers or a missing origin" do
    refute Dispatcher.suppressed?("player", "plex")
    refute Dispatcher.suppressed?("sync:jellyfin", "plex")
    refute Dispatcher.suppressed?(nil, "plex")
    refute Dispatcher.suppressed?(:plugin, "plex")
  end
end
