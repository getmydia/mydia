defmodule Mydia.Indexers.Cardigann.LoginHttpTest do
  use ExUnit.Case, async: true

  import Mydia.CardigannLoginFixtures

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login.Http

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
