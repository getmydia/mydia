defmodule Mydia.Indexers.Cardigann.SearchPagesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.SearchPages
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult

  defp result(title, url) do
    %SearchResult{
      title: title,
      size: 1,
      seeders: 1,
      leechers: 0,
      download_url: url,
      indexer: "Test"
    }
  end

  describe "collect/7 paging deadline" do
    test "requests no later page once the deadline has passed" do
      parsed = %Parsed{id: "pages-deadline", name: "Pages Deadline"}
      parent = self()

      parse = fn _path, _response ->
        send(parent, :parsed)
        {:ok, [result("never", "https://example.test/never")]}
      end

      past = System.monotonic_time(:millisecond) - 1

      assert [] ==
               SearchPages.collect(
                 parsed,
                 [%{path: "/p2"}, %{path: "/p3"}],
                 [paging_deadline: past],
                 %{},
                 %{},
                 "http://127.0.0.1:1",
                 parse
               )

      refute_received :parsed
    end
  end

  describe "dedupe/1" do
    test "keeps every row that has no download url" do
      rows = [result("one", nil), result("two", nil), result("three", "")]

      assert SearchPages.dedupe(rows) == rows
    end

    test "still drops a repeated url and a repeated info hash" do
      a = result("a", "https://example.test/a.torrent")
      b = result("b", "magnet:?xt=urn:btih:ABC123&dn=b")

      rows = [
        a,
        b,
        result("a again", "https://example.test/a.torrent"),
        result("b again", "magnet:?xt=urn:btih:abc123")
      ]

      assert SearchPages.dedupe(rows) == [a, b]
    end
  end
end
