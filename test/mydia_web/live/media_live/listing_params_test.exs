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
end
