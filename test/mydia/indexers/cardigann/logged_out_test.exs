defmodule Mydia.Indexers.Cardigann.LoggedOutTest do
  use ExUnit.Case, async: true

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.LoggedOut

  @parsed parsed("https://tracker.example", %{test: %{path: "/", selector: "a[href*=logout]"}})
  @html %{"content-type" => ["text/html; charset=utf-8"]}

  test "a redirect with cookies is logged out" do
    err =
      {:error,
       Error.search_failed(
         "Redirected (HTTP 302) to /login.php and the redirect was not followed"
       )}

    assert LoggedOut.check(@parsed, err, true) == :logged_out
  end

  test "401/403 with cookies is logged out" do
    assert LoggedOut.check(
             @parsed,
             {:error, Error.connection_failed("Authentication failed")},
             true
           ) ==
             :logged_out
  end

  test "an HTML page without the test selector is logged out" do
    assert LoggedOut.check(
             @parsed,
             {:ok, %{status: 200, body: "<p>login</p>", headers: @html}},
             true
           ) ==
             :logged_out
  end

  test "an HTML page with the selector is fine" do
    body = ~s(<a href="/logout.php">x</a><table></table>)

    assert LoggedOut.check(@parsed, {:ok, %{status: 200, body: body, headers: @html}}, true) ==
             :ok
  end

  test "JSON responses skip the selector test" do
    json = %{"content-type" => ["application/json"]}
    assert LoggedOut.check(@parsed, {:ok, %{status: 200, body: "{}", headers: json}}, true) == :ok
  end

  test "nothing is logged out when no cookies were sent" do
    err =
      {:error,
       Error.search_failed("Redirected (HTTP 302) to /x and the redirect was not followed")}

    assert LoggedOut.check(@parsed, err, false) == :ok
  end
end
