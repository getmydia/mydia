defmodule MydiaWeb.AccessRestrictionLiveUpdateTest do
  # async: false, because connected LiveViews read the DB from their own process.
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Phoenix.LiveViewTest

  alias Mydia.Accounts

  test "upsert and clear broadcast on the user's topic" do
    user = user_fixture()
    Phoenix.PubSub.subscribe(Mydia.PubSub, Accounts.access_restriction_topic(user.id))

    {:ok, _} = Accounts.upsert_access_restriction(user, %{max_content_age: 12})
    assert_receive :access_restriction_changed

    Accounts.clear_access_restriction(user)
    assert_receive :access_restriction_changed
  end

  test "an open page re-navigates when the user's restriction changes", %{conn: conn} do
    user = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/movies")

    {:ok, _} = Accounts.upsert_access_restriction(user, %{max_content_age: 12})

    assert_redirect(view, ~p"/movies")
  end

  test "an open page ignores another user's restriction change", %{conn: conn} do
    user = user_fixture()
    other = user_fixture()

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/movies")

    {:ok, _} = Accounts.upsert_access_restriction(other, %{max_content_age: 12})
    # Sync with the LiveView process so a pending navigation would have landed.
    _ = render(view)

    refute_redirected(view)
  end
end
