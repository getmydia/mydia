defmodule MetadataRelayWeb.DashboardAuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint MetadataRelayWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
    :ok
  end

  test "GET /feedback requires credentials" do
    conn = get(build_conn(), "/feedback")

    assert conn.status == 401
    assert [www_authenticate] = get_resp_header(conn, "www-authenticate")
    assert www_authenticate =~ "Metadata Relay Dashboard"
  end

  test "GET /feedback rejects wrong credentials" do
    conn =
      build_conn()
      |> put_req_header("authorization", basic_auth("admin", "wrong"))
      |> get("/feedback")

    assert conn.status == 401
  end

  test "GET /errors requires credentials" do
    conn = get(build_conn(), "/errors")

    assert conn.status == 401
    assert [_www_authenticate] = get_resp_header(conn, "www-authenticate")
  end

  # `Authorization: Basic Og==` is the base64 of the literal string ":" --
  # empty username, empty password. This test's configured credentials
  # (config/config.exs -- "admin"/"admin", the same fixed values every test
  # in this module runs against) are non-blank, so it correctly gets
  # rejected here regardless of the T-259..T-262 fix: `Plug.BasicAuth`
  # itself is unmodified. What the fix (MetadataRelay.Config, exercised
  # directly in config_test.exs) prevents is the *configured* credentials
  # themselves ever becoming blank in `:prod` -- which is the state under
  # which this same empty-auth header would otherwise succeed, since
  # `Plug.BasicAuth`'s own moduledoc documents that a blank configured
  # user/pass "may be empty strings" and is accepted as such by design.
  test "an empty Authorization header is rejected against the configured (non-blank) credentials" do
    conn =
      build_conn()
      |> put_req_header("authorization", "Basic Og==")
      |> get("/errors")

    assert conn.status == 401
  end

  defp basic_auth(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end
end
