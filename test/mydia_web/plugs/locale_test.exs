defmodule MydiaWeb.Plugs.LocaleTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.Plugs.Locale

  defp run(conn) do
    conn |> Plug.Test.init_test_session(%{}) |> Locale.call(Locale.init([]))
  end

  test "resolves from accept-language and stores the browser locale", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "es-MX,es;q=0.9,en;q=0.5") |> run()

    assert conn.assigns.locale == "es"
    assert get_session(conn, "locale") == "es"
    assert Gettext.get_locale(MydiaWeb.Gettext) == "es"
  end

  test "falls back to en without a usable header", %{conn: conn} do
    conn = conn |> put_req_header("accept-language", "x-klingon") |> run()
    assert conn.assigns.locale == "en"
  end
end
