defmodule MydiaWeb.MobileLayoutManifestTest do
  @moduledoc """
  Every `live` route is either swept by
  `test/mydia_web/features/mobile_layout_sweep_test.exs` or excluded with a
  reason. Runs without a browser so a new route fails the fast suite.
  """
  use ExUnit.Case, async: true

  alias MydiaWeb.MobileLayoutManifest, as: Manifest

  test "every live route is in the manifest" do
    missing = Manifest.live_routes() -- Map.keys(Manifest.entries())

    assert missing == [],
           "Add these routes to test/support/mobile_layout_manifest.ex:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "every manifest entry is a live route" do
    unknown = Map.keys(Manifest.entries()) -- Manifest.live_routes()
    assert unknown == [], "Manifest entries with no live route: #{inspect(unknown)}"
  end

  test "every exclusion has a reason" do
    for {route, {:exclude, reason}} <- Manifest.entries() do
      assert is_binary(reason) and String.length(reason) > 10, "#{route} needs a real reason"
    end
  end

  test "it sees the routes it should" do
    routes = Manifest.live_routes()
    assert "/downloads" in routes
    assert "/admin/users" in routes
    assert "/media/:id" in routes
    assert length(routes) >= 45
  end
end
