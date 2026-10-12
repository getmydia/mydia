defmodule Mydia.Indexers.Cardigann.Bench.MatcherTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Bench.{Matcher, Release}

  defp r(title, opts), do: struct(Release, [title: title] ++ opts)

  test "same title and infohash match" do
    assert Matcher.same?(
             r("Tin Meadow 2032 1080p", info_hash: "ABC"),
             r("tin meadow 2032 1080p", info_hash: "abc")
           )
  end

  test "same title and size within 1% match" do
    assert Matcher.same?(r("Tin Meadow", size: 1_000_000), r("Tin  Meadow", size: 1_009_000))
    refute Matcher.same?(r("Tin Meadow", size: 1_000_000), r("Tin Meadow", size: 1_020_000))
  end

  test "different titles never match, even with the same hash" do
    refute Matcher.same?(r("Tin Meadow", info_hash: "abc"), r("Iron Meadow", info_hash: "abc"))
  end

  test "title normalisation strips surrounding punctuation and case" do
    assert Matcher.same?(r("  [Tin Meadow] - ", size: 5), r("tin meadow", size: 5))
  end

  test "size 0 is unknown on both sides" do
    assert Matcher.same?(r("Tin Meadow", size: 0), r("Tin Meadow", size: nil))
  end

  test "a size on one side only does not match" do
    refute Matcher.same?(r("Tin Meadow", size: 100), r("Tin Meadow", size: nil))
  end

  test "hash match wins over a differing size" do
    assert Matcher.same?(
             r("Tin Meadow", size: 1, info_hash: "abc"),
             r("Tin Meadow", size: 999, info_hash: "ABC")
           )
  end

  test "jaccard over release sets" do
    a = [r("A", size: 1), r("B", size: 1), r("C", size: 1)]
    b = [r("A", size: 1), r("B", size: 1), r("D", size: 1)]
    assert_in_delta Matcher.jaccard(a, b), 0.5, 0.0001
    assert Matcher.jaccard([], []) == 1.0
    assert Matcher.jaccard(a, []) == 0.0
  end

  test "matching is one-to-one, so duplicates do not inflate the score" do
    a = [r("A", size: 1), r("A", size: 1)]
    b = [r("A", size: 1)]
    assert_in_delta Matcher.jaccard(a, b), 0.5, 0.0001
  end

  test "diff lists the unmatched releases on each side" do
    a = [r("A", size: 1), r("B", size: 1)]
    b = [r("A", size: 1), r("C", size: 1)]
    assert %{only_left: [%{title: "B"}], only_right: [%{title: "C"}]} = Matcher.diff(a, b)
  end
end
