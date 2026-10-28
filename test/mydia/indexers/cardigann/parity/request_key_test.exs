defmodule Mydia.Indexers.Cardigann.Parity.RequestKeyTest do
  use ExUnit.Case, async: true
  alias Mydia.Indexers.Cardigann.Parity.RequestKey

  test "query parameter order and encoding do not matter" do
    a = RequestKey.new(:get, "https://Tracker.example/search?q=harbor%20lights&cat=1", nil)
    b = RequestKey.new("GET", "https://tracker.example:443/search?cat=1&q=harbor+lights", nil)
    assert a == b
  end

  test "fragments are dropped and paths kept" do
    assert RequestKey.new(:get, "https://t.example/a/b?x=1#top", nil).url ==
             "https://t.example/a/b?x=1"
  end

  test "form bodies are sorted, other bodies kept verbatim" do
    assert RequestKey.new(:post, "https://t.example/s", "b=2&a=1").body == "a=1&b=2"
    assert RequestKey.new(:post, "https://t.example/s", ~s({"b":2})).body == ~s({"b":2})
  end

  test "different values make different keys" do
    refute RequestKey.new(:get, "https://t.example/s?page=1", nil) ==
             RequestKey.new(:get, "https://t.example/s?page=2", nil)
  end

  test "duplicate parameter names are kept and non-default ports survive" do
    key = RequestKey.new(:get, "http://t.example:8080/s?c=2&c=1", nil)
    assert key.url == "http://t.example:8080/s?c=1&c=2"
  end

  test "a malformed query does not raise" do
    key = RequestKey.new(:get, "https://Example.test/a?q=%zz&b=1", nil)
    # Elixir 1.20 decodes leniently; the rescue in RequestKey is for versions that raise.
    assert key == RequestKey.new(:get, "https://example.test/a?b=1&q=%zz", nil)
  end
end
