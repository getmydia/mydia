defmodule Mydia.Settings.CustomFormats.MatcherTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.CustomFormats.Matcher

  defp format(name, patterns, opts \\ []) do
    {:ok, compiled} = Matcher.compile_patterns(patterns)

    %{
      slug: String.downcase(name),
      name: name,
      score: Keyword.get(opts, :score, 0),
      reject: Keyword.get(opts, :reject, false),
      patterns: compiled
    }
  end

  describe "compile_pattern/1" do
    test "compiles a valid pattern" do
      assert {:ok, _} = Matcher.compile_pattern("\\bVFF\\b")
    end

    test "returns a readable string error for an invalid pattern" do
      assert {:error, message} = Matcher.compile_pattern("(unclosed")
      assert is_binary(message)
      assert message =~ "parenthesis"
    end
  end

  describe "matches?/2" do
    test "matches a tag in a dotted scene title" do
      vff = format("VFF", ["\\bVFF\\b"])
      assert Matcher.matches?("Film.2024.VFF.1080p.WEB-DL.x264-GROUP", vff)
    end

    test "is case insensitive" do
      vff = format("VFF", ["\\bVFF\\b"])
      assert Matcher.matches?("film.2024.vff.1080p", vff)
    end

    test "matches when any one pattern matches" do
      vff = format("VFF", ["\\bVFF\\b", "\\bTRUEFRENCH\\b"])
      assert Matcher.matches?("Film.2024.TRUEFRENCH.1080p", vff)
    end

    test "VQ does not match a release group containing those letters" do
      vfq = format("VFQ", ["\\bVFQ\\b", "\\bVQ\\b"])
      refute Matcher.matches?("Film.2024.1080p.WEB-DL-VQMD", vfq)
    end

    test "MULTI does not match the bare string MULT" do
      multi = format("MULTI", ["\\bMULTI\\b"])
      refute Matcher.matches?("Film.2024.MULT.1080p", multi)
      assert Matcher.matches?("Film.2024.MULTi.1080p", multi)
    end

    test "a catastrophic pattern is bounded and treated as no match" do
      evil = format("Evil", ["(a+)+$"])
      subject = String.duplicate("a", 60) <> "!"

      task = Task.async(fn -> Matcher.matches?(subject, evil) end)
      assert Task.await(task, 2_000) == false
    end
  end

  describe "score_title/2" do
    test "sums the scores of every matching format" do
      formats = [
        format("VFF", ["\\bVFF\\b"], score: 100),
        format("MULTI", ["\\bMULTI\\b"], score: 50)
      ]

      assert %{score: 150, reject: false, matched: matched} =
               Matcher.score_title("Film.2024.MULTI.VFF.1080p", formats)

      assert Enum.sort(matched) == ["MULTI", "VFF"]
    end

    test "reports reject when any matching format rejects" do
      formats = [
        format("VFF", ["\\bVFF\\b"], score: 100),
        format("VFQ", ["\\bVFQ\\b"], reject: true)
      ]

      assert %{reject: true, matched: ["VFQ"]} =
               Matcher.score_title("Film.2024.VFQ.1080p", formats)
    end

    test "a rejecting format contributes no score" do
      formats = [format("VFQ", ["\\bVFQ\\b"], score: 999, reject: true)]
      assert %{score: 0, reject: true} = Matcher.score_title("Film.VFQ.1080p", formats)
    end

    test "returns a zero result when nothing matches" do
      formats = [format("VFF", ["\\bVFF\\b"], score: 100)]

      assert %{score: 0, reject: false, matched: []} =
               Matcher.score_title("Film.2024.1080p", formats)
    end

    test "returns a zero result for an empty format list" do
      assert %{score: 0, reject: false, matched: []} = Matcher.score_title("anything", [])
    end
  end
end
