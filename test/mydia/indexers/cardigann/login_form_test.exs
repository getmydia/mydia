defmodule Mydia.Indexers.Cardigann.LoginFormTest do
  use Mydia.DataCase, async: true

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login
  alias Mydia.Indexers.Cardigann.Login.{Challenge, Session}

  @landing """
  <html><body>
    <form id="login" action="takelogin.php" method="post">
      <input type="hidden" name="csrf" value="tok123">
      <input type="text" name="username">
      <input type="password" name="password">
      <input type="checkbox" name="remember" value="1">
      <input type="checkbox" name="ssl" value="yes" checked>
      <input type="text" name="ghost" disabled value="x">
      <img class="captcha" src="/captcha.php?id=9">
    </form>
    <span id="nonce" data-v="n-77"></span>
  </body></html>
  """

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  defp landing(bypass) do
    Bypass.expect_once(bypass, "GET", "/login.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "PHPSESSID=s1; Path=/")
      |> Plug.Conn.resp(200, @landing)
    end)
  end

  defp expect_submit(bypass, path, assertion) do
    Bypass.expect_once(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assertion.(URI.decode_query(body), conn)

      conn
      |> Plug.Conn.put_resp_header("set-cookie", "uid=7; Path=/")
      |> Plug.Conn.resp(200, "welcome")
    end)
  end

  test "scrapes hidden inputs and posts to the form action", %{bypass: bypass, base: base} do
    landing(bypass)

    expect_submit(bypass, "/takelogin.php", fn params, conn ->
      assert params == %{
               "csrf" => "tok123",
               "username" => "alice",
               "password" => "pw",
               "ssl" => "yes"
             }

      assert Plug.Conn.get_req_header(conn, "cookie") == ["PHPSESSID=s1"]
    end)

    parsed =
      parsed(base, %{
        method: "form",
        form: "form#login",
        inputs: %{"username" => "{{ .Config.username }}", "password" => "{{ .Config.password }}"}
      })

    assert {:ok, %Session{method: :form, cookies: cookies}} =
             Login.begin(parsed, definition(%{"username" => "alice", "password" => "pw"}))

    assert "uid=7" in cookies
  end

  test "a relative action without a leading slash resolves against the login page", %{
    bypass: bypass,
    base: base
  } do
    Bypass.expect_once(bypass, "GET", "/sub/login.php", fn conn ->
      Plug.Conn.resp(conn, 200, @landing)
    end)

    expect_submit(bypass, "/sub/takelogin.php", fn params, _ ->
      assert params["csrf"] == "tok123"
    end)

    parsed = parsed(base, %{method: "form", path: "/sub/login.php"})
    assert {:ok, _} = Login.begin(parsed, definition(%{}))
  end

  test "submitpath overrides the action and selectorinputs read the page", %{
    bypass: bypass,
    base: base
  } do
    landing(bypass)

    expect_submit(bypass, "/do-login", fn params, _conn ->
      assert params["nonce"] == "n-77"
    end)

    parsed =
      parsed(base, %{
        method: "form",
        submitpath: "/do-login",
        selectorinputs: %{
          "nonce" => %{selector: "#nonce", attribute: "data-v", filters: [], optional: false}
        }
      })

    assert {:ok, _} = Login.begin(parsed, definition(%{}))
  end

  test "submitpath renders its template", %{bypass: bypass, base: base} do
    landing(bypass)
    expect_submit(bypass, "/do-login", fn _params, _conn -> :ok end)

    parsed = parsed(base, %{method: "form", submitpath: "/{{ .Config.sub }}"})

    assert {:ok, _} = Login.begin(parsed, definition(%{"sub" => "do-login"}))
  end

  test "a form without an action posts back to the rendered login path", %{
    bypass: bypass,
    base: base
  } do
    Bypass.expect_once(bypass, "GET", "/members/login.php", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<form><input name="username"></form>))
    end)

    expect_submit(bypass, "/members/login.php", fn _params, _conn -> :ok end)

    parsed = parsed(base, %{method: "form", path: "/{{ .Config.area }}/login.php"})

    assert {:ok, _} = Login.begin(parsed, definition(%{"area" => "members"}))
  end

  test "selectors: true resolves input keys to field names", %{bypass: bypass, base: base} do
    landing(bypass)

    expect_submit(bypass, "/takelogin.php", fn params, _ ->
      assert params["username"] == "bob"
    end)

    parsed =
      parsed(base, %{
        method: "form",
        selectors: true,
        inputs: %{"input[type=text]:not([disabled])" => "bob"}
      })

    assert {:ok, _} = Login.begin(parsed, definition(%{}))
  end

  test "an image captcha pauses the login and complete/2 finishes it", %{
    bypass: bypass,
    base: base
  } do
    landing(bypass)

    Bypass.expect_once(bypass, "GET", "/captcha.php", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == ["PHPSESSID=s1"]

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.resp(200, <<137, 80, 78, 71>>)
    end)

    parsed =
      parsed(base, %{
        method: "form",
        captcha: %{type: "image", selector: "img.captcha", input: "imagestring"},
        inputs: %{"username" => "{{ .Config.username }}"}
      })

    definition = definition(%{"username" => "alice"})

    assert {:needs_input,
            %Challenge{fields: ["captcha"], image: <<137, 80, 78, 71>>, image_type: "image/png"} =
              ch} = Login.begin(parsed, definition)

    expect_submit(bypass, "/takelogin.php", fn params, conn ->
      assert params["imagestring"] == "K7QX"
      assert params["username"] == "alice"
      assert Plug.Conn.get_req_header(conn, "cookie") == ["PHPSESSID=s1"]
    end)

    assert {:ok, %Session{method: :form}} = Login.complete(ch, %{"captcha" => "K7QX"})
  end

  test "a 2FA input pauses the login and renders the code", %{bypass: bypass, base: base} do
    landing(bypass)

    parsed =
      parsed(base, %{
        method: "form",
        inputs: %{"username" => "{{ .Config.username }}", "otp" => "{{ .Config.2facode }}"}
      })

    assert {:needs_input, %Challenge{fields: ["2facode"]} = ch} =
             Login.begin(parsed, definition(%{"username" => "alice"}))

    expect_submit(bypass, "/takelogin.php", fn params, _ -> assert params["otp"] == "123456" end)
    assert {:ok, _} = Login.complete(ch, %{"2facode" => "123456"})
  end

  test "a missing form is an authentication error", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/login.php", fn conn ->
      Plug.Conn.resp(conn, 200, "<p>down</p>")
    end)

    parsed = parsed(base, %{method: "form", form: "form#login"})
    assert {:error, %Error{type: :authentication_failed}} = Login.begin(parsed, definition(%{}))
  end

  test "complete/2 with a wrong answer returns the tracker's error", %{
    bypass: bypass,
    base: base
  } do
    landing(bypass)

    Bypass.expect_once(bypass, "GET", "/captcha.php", fn conn ->
      Plug.Conn.resp(conn, 200, "img")
    end)

    parsed =
      parsed(base, %{
        method: "form",
        captcha: %{type: "image", selector: "img.captcha", input: "imagestring"},
        error: [%{selector: "div.err"}]
      })

    {:needs_input, ch} = Login.begin(parsed, definition(%{}))

    Bypass.expect_once(bypass, "POST", "/takelogin.php", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<div class="err">Incorrect captcha</div>))
    end)

    assert {:error, %Error{type: :authentication_failed, message: msg}} =
             Login.complete(ch, %{"captcha" => "nope"})

    assert msg =~ "Incorrect captcha"
  end
end
