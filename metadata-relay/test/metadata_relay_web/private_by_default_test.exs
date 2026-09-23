defmodule MetadataRelayWeb.PrivateByDefaultTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias MetadataRelayWeb.Plug.PrivateByDefault

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
    :ok
  end

  describe "through the endpoint" do
    test "an API route with no policy of its own is private, no-store" do
      conn = get(build_conn(), "/health")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "a maintainer dashboard is private, no-store, even on a 401" do
      conn = get(build_conn(), "/errors")

      assert conn.status == 401
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end

    test "an unknown path is private, no-store" do
      conn = get(build_conn(), "/no-such-route")

      assert conn.status == 404
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  describe "call/2" do
    test "a public header set downstream is left alone" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> PrivateByDefault.call(PrivateByDefault.init([]))
        |> put_resp_header("cache-control", "public, max-age=5")
        |> send_resp(200, "")

      assert get_resp_header(conn, "cache-control") == ["public, max-age=5"]
    end

    test "a non-public header set downstream is replaced" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> PrivateByDefault.call(PrivateByDefault.init([]))
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(500, "")

      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end
end
