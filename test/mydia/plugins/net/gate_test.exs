defmodule Mydia.Plugins.Net.GateTest do
  # DataCase: the gate emits an audit event (Events.create_event_async runs
  # synchronously under the sandbox), so it needs a checked-out connection.
  use Mydia.DataCase, async: true

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Net.Gate

  # A resolver that always returns the given IP tuple(s), bypassing real DNS.
  defp resolver(ips), do: fn _host -> {:ok, List.wrap(ips)} end

  describe "allowlist (exact hostname)" do
    test "AE2: a host not on the grant is denied before any connection" do
      assert {:error, %Error{type: :capability_denied}} =
               Gate.request("https://evil.test/",
                 allowed_hosts: ["discord.com"],
                 resolver: resolver({1, 1, 1, 1})
               )
    end

    test "matches case-insensitively" do
      # Granted but resolves to a private IP, so it fails at the IP stage — which
      # proves the hostname matched (otherwise it would fail at the allowlist).
      assert {:error, %Error{type: :blocked}} =
               Gate.request("https://Discord.COM/",
                 allowed_hosts: ["discord.com"],
                 resolver: resolver({10, 0, 0, 5})
               )
    end
  end

  describe "SSRF IP validation (R6, AE5)" do
    test "rejects 169.254.169.254 even when the hostname is granted" do
      assert {:error, %Error{type: :blocked}} =
               Gate.request("https://metadata.test/",
                 allowed_hosts: ["metadata.test"],
                 resolver: resolver({169, 254, 169, 254})
               )
    end

    test "rejects RFC1918 and loopback" do
      for ip <- [{10, 0, 0, 1}, {172, 16, 5, 5}, {192, 168, 1, 1}, {127, 0, 0, 1}] do
        assert {:error, %Error{type: :blocked}} =
                 Gate.request("https://host.test/",
                   allowed_hosts: ["host.test"],
                   resolver: resolver(ip)
                 )
      end
    end

    test "rejects CGNAT (100.64/10)" do
      assert {:error, %Error{type: :blocked}} =
               Gate.request("https://host.test/",
                 allowed_hosts: ["host.test"],
                 resolver: resolver({100, 64, 0, 1})
               )
    end

    test "rejects IPv4-mapped IPv6 (::ffff:169.254.169.254)" do
      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}

      assert {:error, %Error{type: :blocked}} =
               Gate.request("https://host.test/",
                 allowed_hosts: ["host.test"],
                 resolver: resolver(mapped)
               )
    end

    test "rejects ULA and link-local IPv6" do
      for ip <- [{0xFD00, 0, 0, 0, 0, 0, 0, 1}, {0xFE80, 0, 0, 0, 0, 0, 0, 1}] do
        assert {:error, %Error{type: :blocked}} =
                 Gate.request("https://host.test/",
                   allowed_hosts: ["host.test"],
                   resolver: resolver(ip)
                 )
      end
    end

    test "rejects the call if ANY resolved address is private (deny-if-any)" do
      assert {:error, %Error{type: :blocked}} =
               Gate.request("https://host.test/",
                 allowed_hosts: ["host.test"],
                 resolver: resolver([{1, 1, 1, 1}, {10, 0, 0, 1}])
               )
    end
  end

  describe "URL parsing" do
    test "rejects non-http(s) schemes" do
      assert {:error, %Error{type: :invalid_url}} =
               Gate.request("ftp://host.test/", allowed_hosts: ["host.test"])
    end

    test "rejects userinfo in the URL" do
      assert {:error, %Error{type: :invalid_url}} =
               Gate.request("https://user:pass@host.test/", allowed_hosts: ["host.test"])
    end

    test "rejects decimal and hex integer-literal hosts" do
      assert {:error, %Error{type: :invalid_url}} =
               Gate.request("http://2130706433/", allowed_hosts: ["2130706433"])

      assert {:error, %Error{type: :invalid_url}} =
               Gate.request("http://0x7f000001/", allowed_hosts: ["0x7f000001"])
    end
  end

  describe "live round trip (loopback Bypass via :allow_private seam)" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    defp url(bypass), do: "http://allowed.test:#{bypass.port}/hook"

    test "R6: a granted host with a reachable IP succeeds", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"ok":true}))
      end)

      assert {:ok, %{status: 200, body: body}} =
               Gate.request(url(bypass),
                 allowed_hosts: ["allowed.test"],
                 method: "POST",
                 body: ~s({"content":"hi"}),
                 resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
                 allow_private: true
               )

      assert body =~ "ok"
    end

    test "AE5: a 3xx is returned verbatim, never followed", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:ok, %{status: 302}} =
               Gate.request(url(bypass),
                 allowed_hosts: ["allowed.test"],
                 resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
                 allow_private: true
               )
    end

    test "rejects a response exceeding the size cap", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/hook", fn conn ->
        Plug.Conn.resp(conn, 200, String.duplicate("x", 5_000))
      end)

      assert {:error, %Error{type: :too_large}} =
               Gate.request(url(bypass),
                 allowed_hosts: ["allowed.test"],
                 max_bytes: 100,
                 resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
                 allow_private: true
               )
    end
  end

  describe "timeout" do
    test "a host that never answers hits the connect timeout" do
      # 203.0.113.0/24 is TEST-NET-3 (RFC5737): guaranteed non-routable, so the
      # connection black-holes and the gate's deadline fires cleanly.
      assert {:error, %Error{type: :timeout}} =
               Gate.request("https://blackhole.test/",
                 allowed_hosts: ["blackhole.test"],
                 timeout: 300,
                 resolver: fn _ -> {:ok, [{203, 0, 113, 1}]} end
               )
    end
  end

  describe "audit" do
    test "every outbound call emits a plugin audit event" do
      Gate.request("https://evil.test/",
        allowed_hosts: ["discord.com"],
        slug: "auditor",
        method: "POST",
        resolver: resolver({1, 1, 1, 1})
      )

      events = Mydia.Events.list_events(category: "plugin", type: "plugin.http_request")

      event =
        Enum.find(events, fn e ->
          e.actor_id == "auditor" and e.metadata["outcome"] == "capability_denied"
        end)

      assert event
      assert event.metadata["method"] == "POST"
      assert is_integer(event.metadata["duration_ms"])
    end
  end

  describe "approved endpoints (operator-confirmed private egress)" do
    setup do
      {:ok, bypass: Bypass.open()}
    end

    defp endpoint(host, port, scheme \\ "http"),
      do: %{"scheme" => scheme, "host" => host, "port" => port}

    test "a private address is refused without an approved endpoint" do
      assert {:error, %Error{type: :blocked}} =
               Gate.request("http://plex.lan:32400/identity",
                 allowed_hosts: ["plex.lan"],
                 resolver: resolver({192, 168, 1, 20})
               )
    end

    test "an approved endpoint reaches a private address with no allow_private seam",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/library/sections", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
      end)

      # plex.lan is NOT in allowed_hosts: the approved endpoint alone admits it,
      # and the loopback resolution is allowed only because it is approved.
      assert {:ok, %{status: 200}} =
               Gate.request("http://plex.lan:#{bypass.port}/library/sections",
                 allowed_hosts: [],
                 approved_endpoints: [endpoint("plex.lan", bypass.port)],
                 resolver: resolver({127, 0, 0, 1})
               )
    end

    test "host matching is case-insensitive", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 204, "") end)

      assert {:ok, %{status: 204}} =
               Gate.request("http://PLEX.lan:#{bypass.port}/",
                 approved_endpoints: [endpoint("plex.LAN", bypass.port)],
                 resolver: resolver({127, 0, 0, 1})
               )
    end

    test "a port mismatch is not approved (and the host is not on the allowlist)" do
      assert {:error, %Error{type: :capability_denied}} =
               Gate.request("http://plex.lan:8080/",
                 approved_endpoints: [endpoint("plex.lan", 32400)],
                 resolver: resolver({192, 168, 1, 20})
               )
    end

    test "a port mismatch on a granted host still hits the private-address check" do
      assert {:error, %Error{type: :blocked}} =
               Gate.request("http://plex.lan:8080/",
                 allowed_hosts: ["plex.lan"],
                 approved_endpoints: [endpoint("plex.lan", 32400)],
                 resolver: resolver({192, 168, 1, 20})
               )
    end

    test "a scheme mismatch is not approved" do
      assert {:error, %Error{type: :capability_denied}} =
               Gate.request("https://plex.lan:32400/",
                 approved_endpoints: [endpoint("plex.lan", 32400, "http")],
                 resolver: resolver({192, 168, 1, 20})
               )
    end

    test "another host is never admitted by someone else's approval" do
      assert {:error, %Error{type: :capability_denied}} =
               Gate.request("http://router.lan:32400/",
                 approved_endpoints: [endpoint("plex.lan", 32400)],
                 resolver: resolver({192, 168, 1, 1})
               )
    end

    test "an approved endpoint resolving to link-local (metadata) is still refused" do
      for ip <- [
            {169, 254, 169, 254},
            {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert {:error, %Error{type: :blocked}} =
                 Gate.request("http://meta.lan:80/latest",
                   approved_endpoints: [endpoint("meta.lan", 80)],
                   resolver: resolver(ip)
                 )
      end
    end

    test "an approved endpoint on RFC1918, CGNAT or ULA passes the address check" do
      for ip <- [{10, 1, 2, 3}, {100, 64, 0, 1}, {0xFD00, 0, 0, 0, 0, 0, 0, 5}] do
        result =
          Gate.request("http://plex.lan:9/",
            approved_endpoints: [endpoint("plex.lan", 9)],
            resolver: resolver(ip),
            timeout: 100
          )

        refute match?(
                 {:error, %Error{type: type}} when type in [:blocked, :capability_denied],
                 result
               )
      end
    end

    test "a 3xx from an approved endpoint is returned, not followed", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:ok, %{status: 302, headers: headers}} =
               Gate.request("http://plex.lan:#{bypass.port}/",
                 approved_endpoints: [endpoint("plex.lan", bypass.port)],
                 resolver: resolver({127, 0, 0, 1})
               )

      assert inspect(headers) =~ "169.254.169.254"
    end

    test "the default port is matched when the URL omits it" do
      # http://plex.lan/ means port 80; an endpoint on 80 approves it. The
      # request fails later at connect (nothing listens), which proves both the
      # allowlist and the private check passed.
      assert {:error, %Error{type: type}} =
               Gate.request("http://plex.lan/",
                 approved_endpoints: [endpoint("plex.lan", 80)],
                 resolver: resolver({127, 0, 0, 1}),
                 timeout: 200
               )

      assert type in [:network_error, :timeout]
    end
  end
end
