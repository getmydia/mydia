defmodule Mydia.Indexers.Cardigann.AdapterSupportTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.AdapterSupport
  alias Mydia.Indexers.SearchResult

  defp release(attrs) do
    SearchResult.new(
      Keyword.merge(
        [
          title: "Copper Lantern",
          size: 1024,
          seeders: 1,
          leechers: 0,
          download_url: "https://copper.invalid/1",
          indexer: "Copper",
          category: 4020
        ],
        attrs
      )
    )
  end

  describe "drop_invalid_releases/2 (Prowlarr's IsValidRelease)" do
    test "drops a release with no category or no size outside an interactive search" do
      kept = release([])
      releases = [kept, release(category: nil), release(category: 0), release(size: 0)]

      assert AdapterSupport.drop_invalid_releases(releases, []) == [kept]
    end

    test "keeps them in an interactive search" do
      releases = [release(category: nil), release(size: 0)]
      assert AdapterSupport.drop_invalid_releases(releases, interactive: true) == releases
    end
  end
end
