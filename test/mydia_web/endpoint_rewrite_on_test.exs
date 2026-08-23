defmodule MydiaWeb.EndpointRewriteOnTest do
  @moduledoc """
  Regression coverage for the `Plug.RewriteOn` half of T-007/T-019
  (docs/superpowers/security-review): `MydiaWeb.Endpoint` must not rewrite
  `conn.host` from the client-suppliable `X-Forwarded-Host` header.

  Before the fix, `plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port,
  :x_forwarded_proto]` rewrote `conn.host` unconditionally, with no
  trusted-proxy check, for every request -- including ones that reach this
  app's own exposed port directly (see `Dockerfile:274`) rather than through
  a reverse proxy. That fed `Ueberauth.Strategy.Helpers.full_url/2`'s host
  resolution for the OIDC redirect URI whenever no static override was
  configured. `MydiaWeb.OidcRedirectUri` closes that specific path
  independently now, but this test guards the underlying `conn.host` trust
  directly, since any future code reading `conn.host` would otherwise inherit
  the same problem.

  This exercises the real `Plug.RewriteOn` library plug with the exact option
  list `lib/mydia_web/endpoint.ex` configures, not a reimplementation.
  """

  use ExUnit.Case, async: true

  # Kept in sync with lib/mydia_web/endpoint.ex's `plug Plug.RewriteOn, ...`
  # line -- if that line changes, this constant (and the source-level
  # assertion below) should change with it.
  @configured_rewrites [:x_forwarded_port, :x_forwarded_proto]

  defp conn_with_forwarded_headers do
    :get
    |> Plug.Test.conn("http://mydia.example.com/")
    |> Plug.Conn.put_req_header("x-forwarded-host", "evil.example")
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    |> Plug.Conn.put_req_header("x-forwarded-port", "8443")
  end

  test "the endpoint's configured rewrite list does not include :x_forwarded_host" do
    endpoint_source = File.read!("lib/mydia_web/endpoint.ex")
    [plug_line] = Regex.run(~r/plug Plug\.RewriteOn, \[.*\]/, endpoint_source)

    refute plug_line =~ ":x_forwarded_host"
    assert :x_forwarded_host not in @configured_rewrites
  end

  test "conn.host is left alone even when X-Forwarded-Host is spoofed" do
    conn =
      conn_with_forwarded_headers()
      |> Plug.RewriteOn.call(Plug.RewriteOn.init(@configured_rewrites))

    assert conn.host == "mydia.example.com"
    refute conn.host == "evil.example"
  end

  test "conn.scheme and conn.port still rewrite from the headers this app does trust" do
    conn =
      conn_with_forwarded_headers()
      |> Plug.RewriteOn.call(Plug.RewriteOn.init(@configured_rewrites))

    assert conn.scheme == :https
    assert conn.port == 8443
  end
end
