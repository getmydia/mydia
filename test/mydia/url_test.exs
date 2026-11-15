defmodule Mydia.URLTest do
  use ExUnit.Case, async: true

  alias Mydia.URL

  describe "parse/1" do
    test "keeps an in-range port" do
      assert %URI{host: "plex.lan", port: 32400} = URL.parse("http://plex.lan:32400")
    end

    test "fills the scheme's default port" do
      assert %URI{port: 443} = URL.parse("https://plex.lan")
    end

    test "keeps an out-of-range port as an integer" do
      assert %URI{host: "plex.lan", port: 99_999} = URL.parse("http://plex.lan:99999")
    end

    test "keeps an out-of-range port when URI.new/1 refuses the URL" do
      assert {:error, _} = URI.new("http://localhost:80192/?foo[bar]=baz")

      assert %URI{host: "localhost", port: 80_192} =
               URL.parse("http://localhost:80192/?foo[bar]=baz")
    end

    test "leaves a URL without a port as URI.parse/1 returns it" do
      assert URL.parse("localhost:9696") == URI.parse("localhost:9696")
    end
  end
end
