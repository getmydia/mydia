defmodule MetadataRelay.TrustedProxyTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.TrustedProxy

  describe "trusted?/1 defaults" do
    test "loopback is trusted" do
      assert TrustedProxy.trusted?({127, 0, 0, 1})
      assert TrustedProxy.trusted?({127, 255, 255, 254})
      assert TrustedProxy.trusted?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "RFC1918 private ranges are trusted" do
      assert TrustedProxy.trusted?({10, 0, 0, 1})
      assert TrustedProxy.trusted?({10, 255, 255, 255})
      assert TrustedProxy.trusted?({172, 16, 0, 1})
      assert TrustedProxy.trusted?({172, 31, 255, 255})
      assert TrustedProxy.trusted?({192, 168, 0, 1})
      assert TrustedProxy.trusted?({192, 168, 255, 255})
    end

    test "a public internet address is not trusted" do
      refute TrustedProxy.trusted?({8, 8, 8, 8})
      refute TrustedProxy.trusted?({203, 0, 113, 5})
      # Just outside the 172.16.0.0/12 block (172.32.0.0 is not private)
      refute TrustedProxy.trusted?({172, 32, 0, 1})
    end

    test "requires no operator configuration for the default in-cluster deployment" do
      # The relay's production ingress delivers requests from a private
      # ClusterIP address; nothing here reads an env var, so a fresh
      # deployment gets correct trust behavior with no setup step.
      System.delete_env("RELAY_TRUSTED_PROXY_CIDRS")
      assert TrustedProxy.trusted?({10, 42, 0, 7})
      refute TrustedProxy.trusted?({198, 51, 100, 9})
    end
  end

  describe "trusted?/1 with RELAY_TRUSTED_PROXY_CIDRS override" do
    setup do
      on_exit(fn -> System.delete_env("RELAY_TRUSTED_PROXY_CIDRS") end)
    end

    # Regression guard: explicit configuration must REPLACE the default
    # trusted set, not extend it. An operator configuring a narrower trust
    # boundary (e.g. only their ingress controller's own CIDR) must actually
    # get that narrower boundary -- if the default were still unioned in
    # regardless, there would be no way for any operator to ever restrict
    # this trust boundary below "all of RFC 1918", no matter what they set.
    test "replaces, rather than extends, the default trusted set" do
      System.put_env("RELAY_TRUSTED_PROXY_CIDRS", "203.0.113.0/24")

      assert TrustedProxy.trusted?({203, 0, 113, 5})
      # Defaults no longer apply once the operator has configured a
      # replacement set.
      refute TrustedProxy.trusted?({127, 0, 0, 1})
      refute TrustedProxy.trusted?({10, 0, 0, 1})
      refute TrustedProxy.trusted?({198, 51, 100, 9})
    end

    test "an unset or blank override falls back to the defaults" do
      System.put_env("RELAY_TRUSTED_PROXY_CIDRS", "")
      assert TrustedProxy.trusted?({127, 0, 0, 1})
      assert TrustedProxy.trusted?({10, 0, 0, 1})

      System.put_env("RELAY_TRUSTED_PROXY_CIDRS", "   ")
      assert TrustedProxy.trusted?({127, 0, 0, 1})
      assert TrustedProxy.trusted?({10, 0, 0, 1})
    end

    test "accepts multiple comma-separated CIDRs" do
      System.put_env("RELAY_TRUSTED_PROXY_CIDRS", "203.0.113.0/24, 198.51.100.0/24")

      assert TrustedProxy.trusted?({203, 0, 113, 5})
      assert TrustedProxy.trusted?({198, 51, 100, 9})
    end

    test "ignores a malformed entry rather than crashing" do
      System.put_env("RELAY_TRUSTED_PROXY_CIDRS", "not-a-cidr,203.0.113.0/24")

      assert TrustedProxy.trusted?({203, 0, 113, 5})
      refute TrustedProxy.trusted?({198, 51, 100, 9})
    end
  end

  describe "parse_cidr/1" do
    test "parses an IPv4 CIDR" do
      assert TrustedProxy.parse_cidr("10.0.0.0/8") == {{10, 0, 0, 0}, 8}
    end

    test "parses an IPv6 CIDR" do
      assert TrustedProxy.parse_cidr("::1/128") == {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
    end

    test "rejects garbage" do
      assert TrustedProxy.parse_cidr("garbage") == nil
      assert TrustedProxy.parse_cidr("10.0.0.0/999") == nil
      assert TrustedProxy.parse_cidr("10.0.0.0") == nil
    end
  end
end
