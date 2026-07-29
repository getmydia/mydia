defmodule Mydia.LibrarySearch.TokenizerTest do
  use ExUnit.Case, async: true

  alias Mydia.LibrarySearch.Tokenizer

  describe "normalize/1" do
    test "downcases, trims, and splits on whitespace" do
      assert {:ok, %Tokenizer{query: "night journey", tokens: ["night", "journey"]}} =
               Tokenizer.normalize("  Night   Journey  ")
    end

    test "collapses repeated whitespace in the normalized query" do
      assert {:ok, %Tokenizer{query: "euphoria us"}} = Tokenizer.normalize("Euphoria\t\nUS")
    end

    test "caps at 8 tokens" do
      {:ok, normalized} = Tokenizer.normalize("a b c d e f g h i j k")

      assert length(normalized.tokens) == 8
      assert normalized.tokens == ~w(a b c d e f g h)
    end

    test "returns :empty for a blank query" do
      assert Tokenizer.normalize("") == :empty
    end

    test "returns :empty for a whitespace-only query" do
      assert Tokenizer.normalize("   \t\n  ") == :empty
    end

    test "returns :empty for a non-binary query" do
      assert Tokenizer.normalize(nil) == :empty
    end
  end

  describe "escape_like/1" do
    test "escapes the percent wildcard" do
      assert Tokenizer.escape_like("100%") == "100\\%"
    end

    test "escapes the underscore wildcard" do
      assert Tokenizer.escape_like("a_b") == "a\\_b"
    end

    test "escapes the escape character itself, and does so before the wildcards" do
      assert Tokenizer.escape_like("a\\%b") == "a\\\\\\%b"
    end

    test "leaves ordinary text alone" do
      assert Tokenizer.escape_like("alien") == "alien"
    end
  end

  describe "pattern builders" do
    test "contains_pattern wraps an escaped term in wildcards" do
      assert Tokenizer.contains_pattern("50%") == "%50\\%%"
    end

    test "prefix_pattern anchors at the start" do
      assert Tokenizer.prefix_pattern("back") == "back%"
    end

    test "word_pattern anchors at a word boundary" do
      assert Tokenizer.word_pattern("grey") == "% grey%"
    end
  end
end
