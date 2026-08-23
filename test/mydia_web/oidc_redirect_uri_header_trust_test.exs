defmodule MydiaWeb.OidcRedirectUriHeaderTrustTest do
  @moduledoc """
  Regression coverage for the fix half of T-007/T-019
  (docs/superpowers/security-review): the redirect URI Mydia sends to the
  identity provider must come from configuration, never from a client-
  suppliable request header.

  `Ueberauth.Strategy.Helpers.callback_url/2` -- the function `ueberauth_oidcc`
  calls to build the OIDC `redirect_uri`, both for the request phase (sent to
  the IdP) and the callback phase (compared against what actually came back)
  -- reads `conn.private[:ueberauth_request_options]`. That map is built by
  `Ueberauth.build_strategy_options/2` (`deps/ueberauth/lib/ueberauth.ex`)
  directly from the provider options `config/runtime.exs` configures, pulling
  `:callback_url` straight out of the keyword list with no transformation:

      callback_url: Keyword.get(options, :callback_url)

  So this test builds that same map shape by hand -- once with `:callback_url`
  set the way `config/runtime.exs` now sets it whenever `oidc_redirect_uri` is
  present (explicit or the new production default from
  `MydiaWeb.OidcRedirectUri`), and once without it, reproducing the pre-fix
  configuration shape -- and calls the real, unmodified library function
  against a conn carrying a spoofed `X-Forwarded-Host`/`X-Forwarded-Proto`,
  exactly as `deps/ueberauth/lib/ueberauth/strategies/helpers.ex:248-257`
  reads them. This does not go through a live OIDC issuer (no discovery
  document, no token exchange), because the vulnerability and the fix live
  entirely in how the URL is computed, not in the OIDC handshake itself.
  """

  use ExUnit.Case, async: true

  alias Ueberauth.Strategy.Helpers

  @attacker_host "evil.example"

  defp conn_with_spoofed_headers do
    :get
    |> Plug.Test.conn("https://mydia.example.com/auth/oidc")
    |> Plug.Conn.put_req_header("x-forwarded-host", @attacker_host)
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
  end

  # Mirrors Ueberauth.build_strategy_options/2's output shape
  # (deps/ueberauth/lib/ueberauth.ex:430-451) for the keys callback_url/2 and
  # full_url/2 actually read.
  defp with_request_options(conn, extra_options) do
    options =
      %{
        callback_scheme: nil,
        callback_path: "/auth/oidc/callback",
        callback_port: nil,
        callback_params: nil
      }
      |> Map.merge(Map.new(extra_options))

    Plug.Conn.put_private(conn, :ueberauth_request_options, options)
  end

  test "sanity check: the test conn actually carries the spoofed header" do
    conn = conn_with_spoofed_headers()
    assert Plug.Conn.get_req_header(conn, "x-forwarded-host") == [@attacker_host]
  end

  describe "pre-fix shape: no :callback_url configured (OIDC_REDIRECT_URI unset)" do
    test "callback_url/2 is hijacked by X-Forwarded-Host" do
      conn =
        conn_with_spoofed_headers()
        |> with_request_options(callback_url: nil)

      url = Helpers.callback_url(conn)

      # This is the actual vulnerability: with no static override, the
      # library falls through to full_url/2, which trusts the
      # attacker-suppliable header over the real request. If this assertion
      # ever starts failing, `deps/ueberauth` changed its fallback behavior
      # and the reasoning behind MydiaWeb.OidcRedirectUri needs re-checking.
      assert url =~ @attacker_host
    end
  end

  describe "post-fix shape: :callback_url configured (config/runtime.exs always sets it in :prod)" do
    test "callback_url/2 returns the configured URL verbatim, ignoring the spoofed header" do
      safe_url = MydiaWeb.OidcRedirectUri.default("mydia.example.com")

      conn =
        conn_with_spoofed_headers()
        |> with_request_options(callback_url: safe_url)

      url = Helpers.callback_url(conn)

      assert url == safe_url
      refute url =~ @attacker_host
    end
  end
end
