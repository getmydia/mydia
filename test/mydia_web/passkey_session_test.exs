defmodule MydiaWeb.PasskeySessionTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.PasskeySession

  describe "relying_party/1" do
    test "uses the host of an https request" do
      conn = %{build_conn() | scheme: :https, host: "Mydia.Example.com", port: 443}

      assert {:ok,
              %PasskeySession{rp_id: "mydia.example.com", origin: "https://mydia.example.com"}} =
               PasskeySession.relying_party(conn)
    end

    test "keeps a non-default port in the origin" do
      assert {:ok, %{origin: "https://mydia.example.com:8443"}} =
               PasskeySession.relying_party("https://mydia.example.com:8443/profile")
    end

    test "allows plain http only on localhost" do
      assert {:ok, %{rp_id: "localhost", origin: "http://localhost:4000"}} =
               PasskeySession.relying_party("http://localhost:4000/auth/login")

      assert {:ok, %{rp_id: "mydia.localhost"}} =
               PasskeySession.relying_party("http://mydia.localhost/")

      assert :unavailable = PasskeySession.relying_party("http://mydia.lan/")
    end

    test "never uses an IP address" do
      assert :unavailable = PasskeySession.relying_party("https://192.168.1.10:4443/")
      assert :unavailable = PasskeySession.relying_party("https://[::1]/")
      assert :unavailable = PasskeySession.relying_party("http://127.0.0.1:4000/")
    end

    test "is unavailable for junk" do
      assert :unavailable = PasskeySession.relying_party(nil)
      assert :unavailable = PasskeySession.relying_party("not a url")
    end
  end

  describe "challenges in the session" do
    setup %{conn: conn} do
      %{conn: Plug.Test.init_test_session(conn, %{})}
    end

    test "pop returns the challenge once, for the matching purpose", %{conn: conn} do
      challenge =
        Mydia.Accounts.WebAuthn.authentication_challenge(
          "mydia.test",
          "https://mydia.test",
          "required"
        )

      conn = PasskeySession.put_challenge(conn, :login, challenge)

      assert {nil, conn2} = PasskeySession.pop_challenge(conn, :second_factor)
      assert {nil, _} = PasskeySession.pop_challenge(conn2, :login)

      assert {^challenge, conn} = PasskeySession.pop_challenge(conn, :login)
      assert {nil, _} = PasskeySession.pop_challenge(conn, :login)
    end
  end

  test "credential_param/1 only accepts a map" do
    assert PasskeySession.credential_param(%{"credential" => %{"id" => "x"}}) == %{"id" => "x"}
    assert PasskeySession.credential_param(%{"credential" => "x"}) == %{}
    assert PasskeySession.credential_param(%{}) == %{}
  end
end
