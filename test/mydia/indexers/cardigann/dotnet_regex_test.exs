defmodule Mydia.Indexers.Cardigann.DotnetRegexTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.DotnetRegex

  test "rewrites \\uXXXX to \\x{XXXX}" do
    assert DotnetRegex.to_pcre(~S"[\s\u00A0]+") == ~S"[\s\x{00A0}]+"
  end

  test "leaves an escaped backslash before u alone" do
    assert DotnetRegex.to_pcre(~S"a\\u0041") == ~S"a\\u0041"
  end

  test "keeps the Go rewrites" do
    assert DotnetRegex.to_pcre(~S"(?P<n>\p{IsCyrillic})") == ~S"(?<n>\p{Cyrillic})"
  end

  test "leaves an escaped backslash before p{Is...} alone" do
    assert DotnetRegex.to_pcre(~S"a\\p{IsCyrillic}") == ~S"a\\p{IsCyrillic}"
    assert DotnetRegex.to_pcre(~S"a\\\p{IsCyrillic}") == ~S"a\\\p{Cyrillic}"
  end

  test "leaves an escaped paren before ?P< alone" do
    assert DotnetRegex.to_pcre(~S"\(?P<n>x)") == ~S"\(?P<n>x)"
    assert DotnetRegex.to_pcre(~S"\\(?P<n>x)") == ~S"\\(?<n>x)"
  end

  test "compiles with unicode semantics" do
    assert {:ok, regex} = DotnetRegex.compile(~S"\d+[\s\u00A0]+\d+")
    assert Regex.match?(regex, "2026 12")
  end
end
