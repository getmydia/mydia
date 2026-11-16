defmodule Mydia.Net.Proxy.BypassTest do
  use ExUnit.Case, async: true

  alias Mydia.Net.Proxy.Bypass

  describe "parse/1" do
    test "nil and empty give no entries" do
      assert Bypass.parse(nil) == []
      assert Bypass.parse(" , ,") == []
    end

    test "parses each entry kind" do
      assert Bypass.parse("*, .Example.com., 10.0.0.1, fd00::/8, 198.51.100.0/24, plain.org") == [
               :any,
               {:domain, "example.com"},
               {:ip, {10, 0, 0, 1}},
               {:cidr, {0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8},
               {:cidr, {198, 51, 100, 0}, 24},
               {:domain, "plain.org"}
             ]
    end

    test "drops a trailing port from domain entries" do
      assert Bypass.parse("example.com:8080") == [{:domain, "example.com"}]
    end

    test "a leading *. is a domain entry, matching the domain and its subdomains" do
      entries = Bypass.parse("*.example.com")
      assert entries == [{:domain, "example.com"}]
      assert Bypass.match?("api.example.com", entries)
      assert Bypass.match?("example.com", entries)
      refute Bypass.match?("notexample.com", entries)
    end

    test "drops malformed CIDRs" do
      assert Bypass.parse("10.0.0.0/99,10.0.0.0/x,junk/8") == []
    end
  end

  describe "match?/2" do
    test "domain matches itself and subdomains only" do
      e = Bypass.parse("example.org")
      assert Bypass.match?("example.org", e)
      assert Bypass.match?("a.b.example.org", e)
      refute Bypass.match?("notexample.org", e)
    end

    test "cidr only matches ip literals of the same family" do
      e = Bypass.parse("198.51.100.0/24,fd00::/8")
      assert Bypass.match?("198.51.100.42", e)
      refute Bypass.match?("198.51.101.1", e)
      assert Bypass.match?("fd12::1", e)
      refute Bypass.match?("example.org", e)
    end

    test "any matches everything" do
      assert Bypass.match?("whatever.test", [:any])
    end
  end
end
