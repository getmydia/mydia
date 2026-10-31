defmodule Mydia.Indexers.Cardigann.AdapterSupportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  describe "drop_invalid_releases/3 (Prowlarr's IsValidRelease)" do
    # The suite runs at :warning. A process level cannot lower that (the higher
    # of the two wins), but a module level overrides it, and only for
    # AdapterSupport, so the global level stays put.
    setup do
      Logger.put_module_level(AdapterSupport, :debug)
      on_exit(fn -> Logger.delete_module_level(AdapterSupport) end)
    end

    test "drops a release with no category or no size outside an interactive search" do
      kept = release([])
      releases = [kept, release(category: nil), release(category: 0), release(size: 0)]

      capture_log(fn ->
        assert AdapterSupport.drop_invalid_releases(releases, [], "Copper") == [kept]
      end)
    end

    test "keeps them in an interactive search" do
      releases = [release(category: nil), release(size: 0)]

      assert AdapterSupport.drop_invalid_releases(releases, [interactive: true], "Copper") ==
               releases
    end

    test "logs each dropped release and one warning counting the drops by reason" do
      releases = [
        release([]),
        release(title: "Brass Comet", category: nil),
        release(title: "Tin Harbor", size: 0)
      ]

      log =
        capture_log([level: :debug], fn ->
          AdapterSupport.drop_invalid_releases(releases, [], "Copper")
        end)

      assert log =~ ~s(Copper dropped "Brass Comet": no_category)
      assert log =~ ~s(Copper dropped "Tin Harbor": no_size)
      assert log =~ "[warning]"
      assert log =~ "Copper dropped 2 of 3 releases (no_category: 1, no_size: 1)"
      refute log =~ "category mappings may be stale"
    end

    test "warns that the category mappings may be stale when every release is dropped" do
      releases = [release(category: 0), release(category: nil)]

      log =
        capture_log(fn -> AdapterSupport.drop_invalid_releases(releases, [], "Copper") end)

      assert log =~ "Copper dropped all 2 releases (no_category: 2)"
      assert log =~ "category mappings may be stale"
    end

    test "logs nothing when every release is valid" do
      log =
        capture_log([level: :debug], fn ->
          AdapterSupport.drop_invalid_releases([release([])], [], "Copper")
        end)

      assert log == ""
    end
  end

  describe "put_definition_privacy/2" do
    alias Mydia.Indexers.Structs.TrackerTerms

    test "private and semi-private definitions mark results private" do
      for type <- ["private", "semi-private"] do
        assert [%SearchResult{terms: %TrackerTerms{private?: true}}] =
                 AdapterSupport.put_definition_privacy([release([])], type)
      end
    end

    test "a public definition marks results public and keeps reported factors" do
      reported = %TrackerTerms{download_volume_factor: 0.0}

      assert [
               %SearchResult{
                 terms: %TrackerTerms{private?: false, download_volume_factor: +0.0}
               }
             ] = AdapterSupport.put_definition_privacy([release(terms: reported)], "public")
    end

    test "an unknown type leaves terms alone" do
      assert [%SearchResult{terms: nil}] =
               AdapterSupport.put_definition_privacy([release([])], nil)
    end
  end
end
