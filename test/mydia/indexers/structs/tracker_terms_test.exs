defmodule Mydia.Indexers.Structs.TrackerTermsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms

  describe "from_torznab/1" do
    test "parses every attribute" do
      assert %TrackerTerms{
               download_volume_factor: +0.0,
               upload_volume_factor: 2.0,
               minimum_ratio: 1.0,
               minimum_seed_time: 259_200,
               private?: nil
             } =
               TrackerTerms.from_torznab(%{
                 "downloadvolumefactor" => "0",
                 "uploadvolumefactor" => "2",
                 "minimumratio" => "1.0",
                 "minimumseedtime" => "259200"
               })
    end

    test "half freeleech keeps the fraction" do
      assert %TrackerTerms{download_volume_factor: 0.5} =
               TrackerTerms.from_torznab(%{"downloadvolumefactor" => "0.5"})
    end

    test "blank or unparsable values are unknown" do
      assert TrackerTerms.from_torznab(%{"downloadvolumefactor" => "", "minimumratio" => "x"}) ==
               nil

      assert TrackerTerms.from_torznab(%{}) == nil
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round trip through JSON" do
      terms = %TrackerTerms{
        private?: true,
        minimum_ratio: 1.0,
        minimum_seed_time: 3600,
        download_volume_factor: 0.0,
        upload_volume_factor: 1.0
      }

      decoded = terms |> TrackerTerms.to_map() |> Jason.encode!() |> Jason.decode!()

      assert decoded["private"] == true
      assert decoded["minimum_seed_time"] == 3600
      assert TrackerTerms.from_map(decoded) == terms
    end

    test "from_map accepts atom keys and nil" do
      assert %TrackerTerms{minimum_ratio: 2.0} = TrackerTerms.from_map(%{minimum_ratio: 2})
      assert TrackerTerms.from_map(nil) == nil
    end
  end

  test "empty?/1" do
    assert TrackerTerms.empty?(nil)
    assert TrackerTerms.empty?(%TrackerTerms{})
    refute TrackerTerms.empty?(%TrackerTerms{private?: false})
  end

  test "SearchResult carries terms, nil by default" do
    result =
      SearchResult.new(
        title: "Night Orchard S01E01 1080p",
        size: 1,
        seeders: 1,
        leechers: 0,
        download_url: "magnet:?xt=urn:btih:abc",
        indexer: "Velvet Lantern"
      )

    assert result.terms == nil
    assert %SearchResult{terms: %TrackerTerms{}} = %{result | terms: %TrackerTerms{}}
  end
end
