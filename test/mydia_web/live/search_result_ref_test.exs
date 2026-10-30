defmodule MydiaWeb.Live.SearchResultRefTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.Live.SearchResultRef

  @url "https://tracker.example.test/download/42?passkey=0123456789abcdef"

  test "ref/1 is stable and reveals neither the URL nor the passkey" do
    ref = SearchResultRef.ref(%{download_url: @url, indexer: "Velvet Lantern"})

    assert ref == SearchResultRef.ref(%{download_url: @url, indexer: "Velvet Lantern"})
    assert byte_size(ref) == 16
    refute ref =~ "passkey"
    refute ref =~ "0123456789abcdef"
  end

  test "ref/1 tells the same URL from two trackers apart" do
    refute SearchResultRef.ref(%{download_url: @url, indexer: "Velvet Lantern"}) ==
             SearchResultRef.ref(%{download_url: @url, indexer: "Copper Owl"})
  end

  test "find/2 looks a result up in a list or a map's values" do
    a = %{download_url: @url, indexer: "Velvet Lantern"}
    b = %{download_url: "magnet:?xt=urn:btih:abc", indexer: "Copper Owl"}

    assert SearchResultRef.find([a, b], SearchResultRef.ref(b)) == b
    assert SearchResultRef.find(%{@url => a}, SearchResultRef.ref(a)) == a
    assert SearchResultRef.find([a], "nope") == nil
    assert SearchResultRef.find([a], nil) == nil
  end
end
