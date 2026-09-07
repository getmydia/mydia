defmodule Mydia.P2p.RelayListTest do
  use ExUnit.Case, async: true

  alias Mydia.P2p.RelayList

  @default "https://cae1-1.relay.mydia.dev"
  @fetched "https://relay-one.example.test"
  @other "https://relay-two.example.test"

  setup do
    dir = Path.join(System.tmp_dir!(), "relay_list_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, cache_path: Path.join(dir, "relays.json")}
  end

  # Req accepts a plug as a 1-arity function, which is the cheapest way to
  # stand in for the relay without a socket.
  defp responds(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end
  end

  defp raises do
    fn _conn -> raise "connection refused" end
  end

  defp opts(cache_path, plug, extra \\ []) do
    Keyword.merge(
      [
        cache_path: cache_path,
        base_url: "https://relay.example.test",
        req_options: [plug: plug, retry: false],
        override: nil
      ],
      extra
    )
  end

  describe "override" do
    test "wins outright and makes no request", %{cache_path: cache_path} do
      plug = fn _conn -> raise "the override must not fetch" end

      assert {[@other], :override} =
               RelayList.resolve(opts(cache_path, plug, override: @other))
    end

    test "a blank override is treated as unset", %{cache_path: cache_path} do
      plug = responds(200, ~s({"p2p":{"relays":["#{@fetched}"]}}))

      assert {[@fetched], :fetched} =
               RelayList.resolve(opts(cache_path, plug, override: "   "))
    end

    test "a non-https override is rejected and falls through", %{cache_path: cache_path} do
      plug = responds(200, ~s({"p2p":{"relays":["#{@fetched}"]}}))

      assert {[@fetched], :fetched} =
               RelayList.resolve(opts(cache_path, plug, override: "ftp://nope.example.test"))
    end
  end

  describe "fetch" do
    test "uses the fetched list and writes the cache", %{cache_path: cache_path} do
      plug = responds(200, ~s({"p2p":{"relays":["#{@fetched}","#{@other}"]}}))

      assert {[@fetched, @other], :fetched} = RelayList.resolve(opts(cache_path, plug))
      assert Jason.decode!(File.read!(cache_path)) == [@fetched, @other]
    end

    test "drops entries that are not https URLs", %{cache_path: cache_path} do
      plug =
        responds(200, ~s({"p2p":{"relays":["http://insecure.test","not a url","#{@fetched}"]}}))

      assert {[@fetched], :fetched} = RelayList.resolve(opts(cache_path, plug))
    end

    test "ignores unknown keys in the document", %{cache_path: cache_path} do
      plug = responds(200, ~s({"future":{"thing":1},"p2p":{"relays":["#{@fetched}"],"extra":2}}))

      assert {[@fetched], :fetched} = RelayList.resolve(opts(cache_path, plug))
    end
  end

  describe "fallback" do
    test "a 500 falls back to the cache", %{cache_path: cache_path} do
      File.write!(cache_path, Jason.encode!([@other]))

      assert {[@other], :cached} = RelayList.resolve(opts(cache_path, responds(500, "nope")))
    end

    test "a transport failure falls back to the cache", %{cache_path: cache_path} do
      File.write!(cache_path, Jason.encode!([@other]))

      assert {[@other], :cached} = RelayList.resolve(opts(cache_path, raises()))
    end

    test "malformed JSON falls back to the cache", %{cache_path: cache_path} do
      File.write!(cache_path, Jason.encode!([@other]))

      assert {[@other], :cached} = RelayList.resolve(opts(cache_path, responds(200, "{{{")))
    end

    test "an empty list after filtering falls back to the cache", %{cache_path: cache_path} do
      File.write!(cache_path, Jason.encode!([@other]))
      plug = responds(200, ~s({"p2p":{"relays":["http://insecure.test"]}}))

      assert {[@other], :cached} = RelayList.resolve(opts(cache_path, plug))
    end

    test "no cache falls back to the compiled-in default", %{cache_path: cache_path} do
      assert {[@default], :default} = RelayList.resolve(opts(cache_path, responds(500, "nope")))
    end

    test "an unreadable cache falls back to the compiled-in default", %{cache_path: cache_path} do
      File.write!(cache_path, "{{{ not json")

      assert {[@default], :default} = RelayList.resolve(opts(cache_path, responds(500, "nope")))
    end

    test "a failed fetch does not overwrite a good cache", %{cache_path: cache_path} do
      File.write!(cache_path, Jason.encode!([@other]))

      RelayList.resolve(opts(cache_path, responds(500, "nope")))

      assert Jason.decode!(File.read!(cache_path)) == [@other]
    end
  end

  describe "default_relay_url/0" do
    test "is the relay compiled into this build" do
      assert RelayList.default_relay_url() == @default
    end
  end
end
