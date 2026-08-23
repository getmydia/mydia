defmodule MydiaWeb.OidcRedirectUriTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.OidcRedirectUri

  describe "callback_path/0" do
    test "matches the router's OIDC callback route" do
      assert OidcRedirectUri.callback_path() == "/auth/oidc/callback"
    end
  end

  describe "default/1" do
    test "builds an https URL from the given host" do
      assert OidcRedirectUri.default("mydia.example.com") ==
               "https://mydia.example.com/auth/oidc/callback"
    end

    test "always uses https, regardless of what the host looks like" do
      # Mirrors MydiaWeb.Endpoint's own url: config in config/runtime.exs,
      # which hardcodes scheme: "https" the same way -- URL_SCHEME is
      # documented as having no effect on a release build's generated links.
      assert OidcRedirectUri.default("localhost") == "https://localhost/auth/oidc/callback"
    end

    test "ends with the same path callback_path/0 returns" do
      host = "mydia.example.com"
      assert String.ends_with?(OidcRedirectUri.default(host), OidcRedirectUri.callback_path())
    end
  end
end
