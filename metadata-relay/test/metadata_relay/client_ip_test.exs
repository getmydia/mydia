defmodule MetadataRelay.ClientIpTest do
  @moduledoc """
  Regression tests for T-235/T-236/T-250/T-251/T-253/T-254/T-255/T-257:
  `get_client_ip/1` used to honour a caller-supplied `X-Forwarded-For`
  header unconditionally, taking its leftmost (client-supplied) entry, with
  no check on who actually sent the request. Every IP-keyed rate limit in
  the relay was trivially bypassed by rotating that header.
  """

  use ExUnit.Case, async: true

  alias MetadataRelay.ClientIp

  defp conn_from(remote_ip, forwarded_for \\ nil) do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, remote_ip)

    case forwarded_for do
      nil -> conn
      value -> Plug.Conn.put_req_header(conn, "x-forwarded-for", value)
    end
  end

  describe "an untrusted peer" do
    test "a spoofed X-Forwarded-For is ignored; the real TCP peer is used instead" do
      # 8.8.8.8 is a public address, not a trusted proxy.
      conn = conn_from({8, 8, 8, 8}, "203.0.113.99")

      assert ClientIp.resolve(conn) == "8.8.8.8"
    end

    test "an attacker rotating X-Forwarded-For on every request still resolves to the same identity" do
      ips =
        for spoofed <- ["1.1.1.1", "2.2.2.2", "3.3.3.3"] do
          conn_from({8, 8, 8, 8}, spoofed) |> ClientIp.resolve()
        end

      assert Enum.uniq(ips) == ["8.8.8.8"]
    end

    test "falls back to remote_ip when no header is present at all" do
      conn = conn_from({8, 8, 8, 8})
      assert ClientIp.resolve(conn) == "8.8.8.8"
    end
  end

  describe "a trusted proxy peer (e.g. the in-cluster ingress)" do
    test "honours X-Forwarded-For, taking the rightmost entry" do
      # A single trusted hop appends the real client IP it observed as the
      # last entry; anything to the left could be attacker-supplied.
      conn = conn_from({10, 0, 0, 5}, "203.0.113.7, 10.0.0.5")

      assert ClientIp.resolve(conn) == "10.0.0.5"
    end

    test "a genuine single-entry forwarded value is honoured" do
      conn = conn_from({127, 0, 0, 1}, "203.0.113.7")

      assert ClientIp.resolve(conn) == "203.0.113.7"
    end

    test "falls back to remote_ip when the header is present but blank" do
      conn = conn_from({127, 0, 0, 1}, "")

      assert ClientIp.resolve(conn) == "127.0.0.1"
    end
  end

  describe "Cloudflare fronts this relay, but CF-Connecting-IP is not yet trusted" do
    # Guardrail, not a functional regression test: `CF-Connecting-IP` is a
    # single opaque value Traefik passes through unmodified regardless of
    # who actually connected to it (unlike `X-Forwarded-For`, Traefik does
    # not append its own observed peer to it), and `TrustedProxy.trusted?/1`
    # cannot distinguish "arrived via Cloudflare" from "reached Traefik's
    # public IP directly" -- `conn.remote_ip` is Traefik's in-cluster
    # address either way. Honouring this header today would let a caller
    # who reaches the origin directly pick their own rate-limit identity,
    # reopening T-235/T-236 via a new header name. See the moduledoc for
    # the infra precondition (restricting Traefik's public entrypoint to
    # Cloudflare's published ranges) that would need to hold before this
    # becomes safe to change.
    test "a caller-supplied CF-Connecting-IP does not influence resolution, trusted peer or not" do
      trusted = conn_from({10, 0, 0, 5})
      trusted = Plug.Conn.put_req_header(trusted, "cf-connecting-ip", "198.51.100.9")
      assert ClientIp.resolve(trusted) == "10.0.0.5"

      untrusted = conn_from({8, 8, 8, 8})
      untrusted = Plug.Conn.put_req_header(untrusted, "cf-connecting-ip", "198.51.100.9")
      assert ClientIp.resolve(untrusted) == "8.8.8.8"
    end

    test "an attacker who reaches Traefik directly still cannot pick their own identity via CF-Connecting-IP" do
      ips =
        for spoofed <- ["1.1.1.1", "2.2.2.2", "3.3.3.3"] do
          conn = conn_from({10, 0, 0, 5})
          conn = Plug.Conn.put_req_header(conn, "cf-connecting-ip", spoofed)
          ClientIp.resolve(conn)
        end

      assert Enum.uniq(ips) == ["10.0.0.5"]
    end
  end
end
