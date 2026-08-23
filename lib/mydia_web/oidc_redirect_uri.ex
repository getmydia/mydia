defmodule MydiaWeb.OidcRedirectUri do
  @moduledoc """
  Derives the OIDC callback redirect URI Mydia presents to an identity
  provider, for the case where the operator has not set `OIDC_REDIRECT_URI`
  explicitly.

  Extracted out of `config/runtime.exs` as a plain function so it has direct
  unit test coverage -- boot-time script code in `runtime.exs` itself is not
  otherwise reachable from ExUnit.

  ## Why this exists

  `Ueberauth.Strategy.Helpers.full_url/2` (used internally by
  `ueberauth_oidcc` to build the `redirect_uri` sent to the identity
  provider) falls back to the client-suppliable `X-Forwarded-Host` /
  `X-Forwarded-Proto` request headers whenever no static `:callback_url` /
  `:callback_scheme` option is configured for the strategy -- independently
  of `Plug.RewriteOn`, which trusts the same headers for `conn.host` /
  `conn.scheme` elsewhere. An attacker who can reach the origin (this app's
  own Dockerfile exposes its HTTP port directly, and the documented
  reverse-proxy config never strips `X-Forwarded-Host`) can steer that
  `redirect_uri` to a host they control (see
  docs/superpowers/security-review, findings T-007/T-019).

  `PHX_HOST` is already required configuration for any Mydia deployment
  reachable at a real hostname -- both `MydiaWeb.Endpoint`'s own `url:` and
  `PHX_CHECK_ORIGIN` key off it, and LiveView's websocket would fail its own
  origin check without it. `docs/using/how-to/sso-oidc.md` and
  `docs/using/reference/environment-variables.md` already document
  `https://{PHX_HOST}/auth/oidc/callback` as the auto-computed redirect URI --
  this module is what makes that documentation true, rather than asking an
  operator to configure anything new.

  `config/runtime.exs` only calls `default/1` when `config_env() == :prod`:
  dev/test have no reverse proxy in front of them, no attacker positioned to
  forge these headers, and `docs/using/how-to/sso-oidc.md`'s own Quick Start
  sets `OIDC_REDIRECT_URI` explicitly for local testing rather than relying
  on this. An operator's own `OIDC_REDIRECT_URI` always wins over this
  default.
  """

  @callback_path "/auth/oidc/callback"

  @doc "The path every OIDC redirect URI ends with (`GET`/`POST /auth/:provider/callback`)."
  @spec callback_path() :: String.t()
  def callback_path, do: @callback_path

  @doc """
  The default production redirect URI for `host` (normally `PHX_HOST`, or its
  own placeholder fallback when unset).

  Always `https`: a release build hardcodes its own external URL the same
  way (`MydiaWeb.Endpoint`'s `url:` config in `config/runtime.exs`), and
  `docs/using/reference/environment-variables.md` documents that an operator
  serving Mydia over plain http must set `OIDC_REDIRECT_URI` explicitly
  rather than rely on this default.
  """
  @spec default(String.t()) :: String.t()
  def default(host) when is_binary(host), do: "https://#{host}#{@callback_path}"
end
