defmodule MydiaWeb.Plugs.RuntimeUeberauthTest do
  use MydiaWeb.ConnCase

  setup do
    original = Application.get_env(:ueberauth, Ueberauth)

    Application.put_env(:ueberauth, Ueberauth,
      providers: [timeout_provider: {MydiaWeb.TimeoutUeberauthStrategy, []}]
    )

    on_exit(fn ->
      if original do
        Application.put_env(:ueberauth, Ueberauth, original)
      else
        Application.delete_env(:ueberauth, Ueberauth)
      end
    end)

    :ok
  end

  describe "GET /auth/:provider when the provider worker times out" do
    test "redirects to the login page with a flash error instead of crashing", %{conn: conn} do
      conn = get(conn, ~p"/auth/timeout_provider")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "identity provider"
    end
  end
end
