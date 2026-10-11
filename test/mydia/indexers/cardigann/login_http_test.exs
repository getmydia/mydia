defmodule Mydia.Indexers.Cardigann.LoginHttpTest do
  use ExUnit.Case, async: true

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login.{Http, Inputs}

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  test "follows a same-origin redirect and keeps cookies from every hop", %{
    bypass: bypass,
    base: base
  } do
    Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "a=1; Path=/")
      |> Plug.Conn.put_resp_header("location", "/home.php")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.expect_once(bypass, "GET", "/home.php", fn conn ->
      assert Plug.Conn.get_req_header(conn, "cookie") == ["a=1"]
      conn |> Plug.Conn.put_resp_header("set-cookie", "b=2") |> Plug.Conn.resp(200, "home")
    end)

    ctx = Http.new_ctx(parsed(base, %{}), %{}, [])

    assert {:ok, %{status: 200, body: "home"}, ctx} =
             Http.request(ctx, :post, base <> "/login.php", form: %{})

    assert Enum.sort(Http.cookies(ctx)) == ["a=1", "b=2"]
  end

  test "resolves a relative Location against the request URL", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "POST", "/sub/login.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "home.php")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.expect_once(bypass, "GET", "/sub/home.php", fn conn ->
      Plug.Conn.resp(conn, 200, "sub home")
    end)

    ctx = Http.new_ctx(parsed(base, %{}), %{}, [])

    assert {:ok, %{status: 200, body: "sub home"}, _ctx} =
             Http.request(ctx, :post, base <> "/sub/login.php", form: %{})
  end

  test "resolve_page keeps the page path and drops its query string" do
    assert Inputs.resolve_page("http://h/sub/login.php?a=1", "home.php?b=2") ==
             "http://h/sub/home.php?b=2"

    assert Inputs.resolve_page("http://h/sub/login.php?a=1", "/x") == "http://h/x"
  end

  test "resolve joins a relative login path onto the site link and keeps an absolute one" do
    assert Inputs.resolve("https://abn.lol", "/login.php") == "https://abn.lol/login.php"

    assert Inputs.resolve("https://abn.lol", "https://auth.abn.lol/api/login") ==
             "https://auth.abn.lol/api/login"
  end

  test "base_url names the site link as the problem when the definition has none" do
    alias Mydia.Indexers.CardigannDefinition

    parsed = %{parsed("http://unused.example", %{}) | links: []}

    assert {:error, %Error{message: message}} =
             Inputs.base_url(parsed, %CardigannDefinition{config: %{}, active_link: nil})

    assert message =~ "No site link configured"
  end

  test "refuses a redirect to a host outside the definition", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example/steal")
      |> Plug.Conn.resp(302, "")
    end)

    ctx = Http.new_ctx(parsed(base, %{}), %{}, [])

    assert {:error, %Error{type: :connection_failed}} =
             Http.request(ctx, :post, base <> "/login.php", form: %{})
  end

  test "refuses a cleartext non-loopback login URL" do
    ctx = Http.new_ctx(parsed("http://tracker.example", %{}), %{}, [])

    assert {:error, %Error{type: :connection_failed, message: message}} =
             Http.request(ctx, :post, "http://tracker.example/login.php",
               form: %{"password" => "x"}
             )

    assert message =~ "unencrypted"
  end
end
