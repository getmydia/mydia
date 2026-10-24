defmodule MydiaWeb.LocaleIntegrationTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Accounts

  test "login page takes the browser language", %{conn: conn} do
    user_fixture()
    conn = conn |> put_req_header("accept-language", "es") |> get(~p"/auth/login")

    assert html_response(conn, 200) =~ ~s(<html lang="es")
  end

  test "a signed-in user's preference beats the browser", %{conn: conn} do
    user = user_fixture()

    {:ok, _} =
      user
      |> Accounts.get_user_preference!()
      |> Accounts.update_preference(%{"interface_language" => "es"})

    conn = conn |> log_in_user(user) |> put_req_header("accept-language", "en")
    {:ok, view, html} = live(conn, ~p"/profile")

    assert html =~ ~s(<html lang="es")
    assert lv_locale(view) == "es"
  end

  test "auto follows the browser inside LiveView", %{conn: conn} do
    user = user_fixture()
    conn = conn |> log_in_user(user) |> put_req_header("accept-language", "es")
    {:ok, view, _html} = live(conn, ~p"/profile")

    assert lv_locale(view) == "es"
  end

  defp es(msgid),
    do:
      Gettext.with_locale(MydiaWeb.Gettext, "es", fn ->
        Gettext.gettext(MydiaWeb.Gettext, msgid)
      end)

  test "the login page renders Spanish text for a Spanish browser", %{conn: conn} do
    user_fixture()
    conn = conn |> put_req_header("accept-language", "es") |> get(~p"/auth/login")

    refute es("Sign In") == "Sign In"

    heading =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#login-heading")

    assert Enum.count(heading) == 1
    assert heading |> LazyHTML.text() |> String.trim() == es("Sign In")
  end

  test "the profile page is Spanish for a Spanish user", %{conn: conn} do
    user = user_fixture()

    {:ok, _} =
      user
      |> Accounts.get_user_preference!()
      |> Accounts.update_preference(%{"interface_language" => "es"})

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/profile")

    refute es("Language") == "Language"

    title =
      view
      |> element("#interface-language-title")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert title == es("Language")
  end

  test "a preference row without interface_language follows the browser", %{conn: conn} do
    # Rows written before interface translations shipped lose a stored "en" in
    # 20261024164324_reset_default_interface_language, leaving no key at all.
    user = user_fixture()

    user
    |> Accounts.get_user_preference!()
    |> Ecto.Changeset.change(preferences: %{"theme" => "dark"})
    |> Mydia.Repo.update!()

    conn = conn |> log_in_user(user) |> put_req_header("accept-language", "es")
    {:ok, view, html} = live(conn, ~p"/profile")

    assert html =~ ~s(<html lang="es")
    assert lv_locale(view) == "es"
  end

  test "first-run setup takes the browser language", %{conn: conn} do
    refute Accounts.any_users_exist?()

    conn = put_req_header(conn, "accept-language", "es")
    {:ok, view, html} = live(conn, ~p"/setup")

    assert html =~ ~s(<html lang="es")
    assert lv_locale(view) == "es"
  end

  # Gettext.put_locale/2 stores the locale in the calling process's dictionary
  # under the backend module, so this reads what the LiveView process will
  # translate with.
  defp lv_locale(view) do
    {:dictionary, dict} = Process.info(view.pid, :dictionary)
    {MydiaWeb.Gettext, locale} = List.keyfind(dict, MydiaWeb.Gettext, 0)
    locale
  end
end
