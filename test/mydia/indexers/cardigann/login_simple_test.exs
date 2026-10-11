defmodule Mydia.Indexers.Cardigann.LoginSimpleTest do
  use Mydia.DataCase, async: true

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login
  alias Mydia.Indexers.Cardigann.Login.Session

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  describe "cookie method" do
    test "uses the definition's `cookie` setting", %{base: base} do
      parsed = parsed(base, %{method: "cookie", path: nil})
      definition = definition(%{"cookie" => "uid=7; pass=abc"})

      assert {:ok, %Session{method: :cookie, cookies: cookies}} = Login.begin(parsed, definition)
      assert Enum.sort(cookies) == ["pass=abc", "uid=7"]
    end

    test "is an authentication error when no cookie is configured", %{base: base} do
      parsed = parsed(base, %{method: "cookie", path: nil})

      assert {:error, %Error{type: :authentication_failed}} =
               Login.begin(parsed, definition(%{}))
    end
  end

  describe "get method" do
    test "renders .Config.apikey into the query string", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "GET", "/api/login", fn conn ->
        assert conn.query_string == "key=s3cret"

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=xyz; Path=/; HttpOnly")
        |> Plug.Conn.resp(200, "<a href=\"/logout\">out</a>")
      end)

      parsed =
        parsed(base, %{
          method: "get",
          path: "/api/login",
          inputs: %{"key" => "{{ .Config.apikey }}"}
        })

      assert {:ok, %Session{method: :get, cookies: ["session=xyz"]}} =
               Login.begin(parsed, definition(%{"apikey" => "s3cret"}))
    end
  end

  describe "post method" do
    test "renders every .Config value and seeds login.cookies", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params == %{"username" => "alice", "password" => "pw", "pin" => "4321"}
        assert Plug.Conn.get_req_header(conn, "cookie") == ["lang=en"]
        assert Plug.Conn.get_req_header(conn, "x-requested-with") == ["XMLHttpRequest"]

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "uid=7; Path=/")
        |> Plug.Conn.resp(200, "ok")
      end)

      parsed =
        parsed(base, %{
          method: "post",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}",
            "pin" => "{{ .Config.pin }}"
          },
          cookies: ["lang=en"],
          headers: %{"X-Requested-With" => ["XMLHttpRequest"]}
        })

      config = %{"username" => "alice", "password" => "pw", "pin" => "4321"}

      assert {:ok, %Session{method: :post, cookies: cookies}} =
               Login.begin(parsed, definition(config))

      assert "uid=7" in cookies
    end

    test "surfaces the login.error text", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        Plug.Conn.resp(conn, 200, ~s(<div class="error">Wrong password</div>))
      end)

      parsed = parsed(base, %{method: "post", error: [%{selector: "div.error"}]})

      assert {:error, %Error{type: :authentication_failed, message: message}} =
               Login.begin(parsed, definition(%{"username" => "a", "password" => "b"}))

      assert message =~ "Wrong password"
    end

    test "fails when login.test's selector is missing", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        conn |> Plug.Conn.put_resp_header("set-cookie", "uid=7") |> Plug.Conn.resp(200, "ok")
      end)

      Bypass.expect_once(bypass, "GET", "/index.php", fn conn ->
        Plug.Conn.resp(conn, 200, "<p>Please log in</p>")
      end)

      parsed =
        parsed(base, %{method: "post", test: %{path: "/index.php", selector: "a[href*=logout]"}})

      assert {:error, %Error{type: :authentication_failed}} =
               Login.begin(parsed, definition(%{"username" => "a", "password" => "b"}))
    end
  end

  test "a definition with no login block is an anonymous session", %{base: base} do
    parsed = %{parsed(base, %{}) | login: nil}
    assert {:ok, %Session{method: :none, cookies: []}} = Login.begin(parsed, definition(%{}))
  end
end
