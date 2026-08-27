defmodule Mydia.Metadata.Structs.SearchResultTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.SearchResult

  test "carries TMDB genre ids through from the search payload" do
    result =
      SearchResult.from_api_response(
        %{"id" => 1, "title" => "Toon", "genre_ids" => [16, 35]},
        media_type: :movie
      )

    assert result.genre_ids == [16, 35]
  end

  test "defaults to an empty list when the payload has no genre ids" do
    result = SearchResult.from_api_response(%{"id" => 2, "title" => "Bare"}, media_type: :movie)

    assert result.genre_ids == []
  end

  test "carries the origin signals TMDB sends with each hit" do
    result =
      SearchResult.from_api_response(
        %{
          "id" => 3,
          "name" => "Shonen",
          "genre_ids" => [16],
          "origin_country" => ["JP"],
          "original_language" => "ja"
        },
        media_type: :tv_show
      )

    assert result.origin_country == ["JP"]
    assert result.original_language == "ja"
  end

  test "defaults the origin signals when the payload omits them" do
    result = SearchResult.from_api_response(%{"id" => 4, "title" => "Bare"}, media_type: :movie)

    assert result.origin_country == []
    assert result.original_language == nil
  end
end
