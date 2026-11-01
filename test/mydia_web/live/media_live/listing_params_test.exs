defmodule MydiaWeb.MediaLive.Index.ListingParamsTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Index.ListingParams

  @lib "0b6c1d52-6b1e-4d8e-9f7e-3f0d6c2a9a11"

  test "empty params give the defaults" do
    assert ListingParams.parse(%{}, []) == %ListingParams{}
    assert ListingParams.to_query(%ListingParams{}) == []
    assert ListingParams.path("/movies", %ListingParams{}) == "/movies"
    refute ListingParams.filtered?(%ListingParams{})
  end

  test "upcoming is a valid progress filter" do
    parsed = ListingParams.parse(%{"progress" => "upcoming"}, [])

    assert parsed.progress == :upcoming
    assert ListingParams.to_query(parsed) == [{"progress", "upcoming"}]
  end

  test "downloading is a valid progress filter" do
    parsed = ListingParams.parse(%{"progress" => "downloading"}, [])

    assert parsed.progress == :downloading
    assert ListingParams.to_query(parsed) == [{"progress", "downloading"}]
  end

  test "valid params round-trip through the query string" do
    params = %{
      "q" => "harbor",
      "library" => @lib,
      "progress" => "missing",
      "monitored" => "false",
      "quality" => "2160p",
      "sort" => "added_desc",
      "shown" => "200"
    }

    parsed = ListingParams.parse(params, [@lib])

    assert parsed == %ListingParams{
             search: "harbor",
             library: @lib,
             progress: :missing,
             monitored: false,
             quality: "2160p",
             sort: "added_desc",
             shown: 200
           }

    assert Map.new(ListingParams.to_query(parsed)) == params
    assert ListingParams.filtered?(parsed)
  end

  test "invalid values fall back to defaults" do
    parsed =
      ListingParams.parse(
        %{
          "library" => @lib,
          "progress" => "bogus",
          "monitored" => "all",
          "quality" => "8k",
          "sort" => "drop_table",
          "shown" => "lots"
        },
        []
      )

    assert parsed == %ListingParams{}
  end

  test "shown is clamped to 50..1000" do
    assert ListingParams.parse(%{"shown" => "10"}, []).shown == 50
    assert ListingParams.parse(%{"shown" => "5000"}, []).shown == 1000
  end

  test "a non-default sort alone counts as filtered" do
    assert ListingParams.filtered?(%ListingParams{sort: "year_desc"})
    refute ListingParams.filtered?(%ListingParams{shown: 300})
  end

  test "same_listing? ignores shown" do
    assert ListingParams.same_listing?(%ListingParams{shown: 50}, %ListingParams{shown: 400})
    refute ListingParams.same_listing?(%ListingParams{}, %ListingParams{search: "x"})
  end

  test "max_shown is the cap parse applies" do
    assert ListingParams.max_shown() == 1000
  end

  test "path encodes the query" do
    assert ListingParams.path("/tv", %ListingParams{search: "a b", progress: :partial}) ==
             "/tv?q=a+b&progress=partial"
  end

  describe "letter" do
    test "parses # and a-z, lowercased" do
      assert ListingParams.parse(%{"letter" => "M"}, []).letter == "m"
      assert ListingParams.parse(%{"letter" => "#"}, []).letter == "#"
    end

    test "rejects anything else" do
      for value <- ["mm", "", "1", "é", nil, ["m"]] do
        assert ListingParams.parse(%{"letter" => value}, []).letter == nil
      end
    end

    test "round-trips through the query string" do
      params = %ListingParams{letter: "#", shown: 100}
      query = ListingParams.to_query(params)
      assert {"letter", "#"} in query
      assert ListingParams.parse(Map.new(query), []) == params
      assert ListingParams.path("/movies", params) == "/movies?letter=%23&shown=100"
    end

    test "a jump alone is not a filter, but is a different listing" do
      refute ListingParams.filtered?(%ListingParams{letter: "m"})
      refute ListingParams.same_listing?(%ListingParams{letter: "m"}, %ListingParams{})
    end
  end

  describe "above" do
    test "parses a non-negative count clamped to max_shown, 0 otherwise" do
      assert ListingParams.parse(%{"above" => "48"}, []).above == 48
      assert ListingParams.parse(%{"above" => "5000"}, []).above == 1000

      for value <- ["-3", "lots", "", nil, ["48"]] do
        assert ListingParams.parse(%{"above" => value}, []).above == 0
      end
    end

    test "round-trips through the query string, and is left out at 0" do
      params = %ListingParams{letter: "m", above: 96}
      assert ListingParams.path("/movies", params) == "/movies?letter=m&above=96"
      assert ListingParams.parse(%{"letter" => "m", "above" => "96"}, []) == params
      assert ListingParams.path("/movies", %{params | above: 0}) == "/movies?letter=m"
    end

    test "is neither a filter nor a different listing" do
      refute ListingParams.filtered?(%ListingParams{above: 48})

      assert ListingParams.same_listing?(
               %ListingParams{letter: "m", above: 48},
               %ListingParams{letter: "m"}
             )
    end
  end

  describe "to_remembered/1" do
    test "keeps sort and filters, drops search, letter and window" do
      params = %ListingParams{
        search: "fern",
        library: "lib-1",
        progress: :missing,
        monitored: false,
        quality: "2160p",
        sort: "year_desc",
        letter: "m",
        shown: 150,
        above: 50
      }

      assert ListingParams.to_remembered(params) == %{
               "library" => "lib-1",
               "progress" => "missing",
               "monitored" => "false",
               "quality" => "2160p",
               "sort" => "year_desc"
             }
    end

    test "defaults remember nothing" do
      assert ListingParams.to_remembered(%ListingParams{}) == %{}
    end
  end

  describe "listing_in_url?/1" do
    test "true when any remembered key is present" do
      for key <- ListingParams.remembered_keys() do
        assert ListingParams.listing_in_url?(%{key => "x"})
      end
    end

    test "false for search, letter and window params only" do
      refute ListingParams.listing_in_url?(%{"q" => "fern", "letter" => "m", "shown" => "100"})
      refute ListingParams.listing_in_url?(%{})
    end
  end
end
