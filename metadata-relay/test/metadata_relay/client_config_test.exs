defmodule MetadataRelay.ClientConfigTest do
  use ExUnit.Case, async: true

  # Plug 1.18 deprecates `use Plug.Test`, and this suite is on 1.20.3, so
  # follow the rest of it: call Plug.Test.conn/2 fully qualified and import
  # only what is needed from Plug.Conn.
  import Plug.Conn, only: [get_resp_header: 2]

  alias MetadataRelay.ClientConfig

  describe "relay_urls/0" do
    test "lists the mydia-operated iroh relays" do
      urls = ClientConfig.relay_urls()

      assert is_list(urls)
      assert "https://cae1-1.relay.mydia.dev" in urls
    end

    test "every entry is an https URL with a host" do
      for url <- ClientConfig.relay_urls() do
        uri = URI.parse(url)
        assert uri.scheme == "https", "#{url} is not https"
        assert is_binary(uri.host) and uri.host != "", "#{url} has no host"
      end
    end
  end

  describe "GET /client-config" do
    test "returns the p2p relay list as JSON" do
      conn = MetadataRelay.Router.call(Plug.Test.conn(:get, "/client-config"), [])

      assert conn.status == 200
      assert conn.state == :sent

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      body = Jason.decode!(conn.resp_body)
      assert %{"p2p" => %{"relays" => relays}} = body
      assert relays == MetadataRelay.ClientConfig.relay_urls()
    end
  end
end
