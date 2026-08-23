defmodule MetadataRelayWeb.EndpointSessionTest do
  use ExUnit.Case, async: true

  test "session cookies are encrypted, not merely signed" do
    opts = MetadataRelayWeb.Endpoint.session_options()

    assert Keyword.fetch!(opts, :store) == :cookie
    assert is_binary(Keyword.get(opts, :encryption_salt))
    assert Keyword.get(opts, :encryption_salt) != Keyword.get(opts, :signing_salt)
  end
end
