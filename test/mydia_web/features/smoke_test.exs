defmodule MydiaWeb.Features.SmokeTest do
  @moduledoc """
  Proves the application boots in a real browser: assets built, JS loaded,
  LiveView socket connected.

  Deliberately one test. Page loads, titles and redirect behavior are
  covered far more cheaply in `MydiaWeb.SessionControllerTest` and
  `MydiaWeb.RouteAuthorizationTest`. What only a browser can prove is that
  the asset pipeline produced JS that actually connects a socket.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "Application Smoke Test" do
    @tag :feature
    test "the LiveView socket connects on the dashboard", %{session: session} do
      login_as_admin(session)

      session
      |> visit("/")
      |> wait_for_liveview()

      assert Wallaby.Browser.has_css?(session, "[data-phx-main].phx-connected")
    end
  end
end
