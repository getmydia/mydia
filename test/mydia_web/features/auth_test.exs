defmodule MydiaWeb.Features.AuthTest do
  @moduledoc """
  Login and logout driven through the rendered form in a real browser.

  Scope is deliberately narrow. Role and redirect behavior lives in
  `MydiaWeb.RouteAuthorizationTest`, and the POST handler in
  `MydiaWeb.SessionControllerTest`. What only a browser proves is that the
  rendered form submits and the resulting session drives a connected
  LiveView. Every other browser test depends on this path, so it is worth
  the seconds it costs.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  describe "Local Authentication" do
    @tag :feature
    test "a user can log in through the rendered form", %{session: session} do
      user = create_admin_user()

      session
      |> visit("/auth/local/login")
      |> fill_in(Query.text_field("user[username]"), with: user.username)
      |> fill_in(Query.text_field("user[password]"), with: "password123")
      |> click(Query.button("Log In"))

      session
      |> wait_for_liveview()
      |> assert_path("/")
      |> assert_has_text("Dashboard")
    end

    @tag :feature
    test "a logged-in user can log out", %{session: session} do
      login_as_admin(session)

      session
      |> wait_for_liveview()
      |> assert_path("/")

      session
      |> visit("/auth/logout")

      assert Wallaby.Browser.current_path(session) =~ ~r{/auth/(local/)?login}
    end
  end
end
