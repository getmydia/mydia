defmodule Mydia.Metadata.Structs.SearchResultTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.SearchResult

  describe "from_api_response/2" do
    test "carries the honest provider, not the config type that served it" do
      result =
        SearchResult.from_api_response(
          %{"id" => 42, "title" => "The Wandering Comet"},
          media_type: :movie
        )

      assert result.provider == :tmdb
    end

    test "stringifies the provider id" do
      result =
        SearchResult.from_api_response(
          %{"id" => 42, "title" => "The Wandering Comet"},
          media_type: :movie
        )

      assert result.provider_id == "42"
    end

    test "infers media_type from the API response when no override is given" do
      tv_result = SearchResult.from_api_response(%{"id" => 1, "name" => "Harbour Lights"})
      assert tv_result.media_type == :movie

      tv_result_with_hint =
        SearchResult.from_api_response(%{
          "id" => 2,
          "name" => "Harbour Lights",
          "media_type" => "tv"
        })

      assert tv_result_with_hint.media_type == :tv_show
    end

    test "honors an explicit media_type override" do
      result =
        SearchResult.from_api_response(%{"id" => 3, "name" => "Harbour Lights"},
          media_type: :tv_show
        )

      assert result.media_type == :tv_show
    end
  end
end
