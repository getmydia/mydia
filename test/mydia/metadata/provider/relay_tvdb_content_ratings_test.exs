defmodule Mydia.Metadata.Provider.RelayTvdbContentRatingsTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.MediaMetadata

  # transform_tvdb_to_tmdb_format/4 is private, so this exercises it through
  # the public normalization entry point the provider uses.
  defp transform(content_ratings) do
    %{
      "id" => 12_345,
      "name" => "Test Series",
      "firstAired" => "2020-01-01",
      "contentRatings" => content_ratings
    }
    |> Mydia.Metadata.Provider.Relay.normalize_tvdb_series(:tv_show, "eng", [])
  end

  test "emits US ratings under TMDB's content_ratings shape" do
    result = transform([%{"name" => "TV-14", "country" => "usa"}])

    assert %{"content_ratings" => %{"results" => [entry]}} = result
    assert entry["iso_3166_1"] == "US"
    assert entry["rating"] == "TV-14"
  end

  test "MediaMetadata reads the emitted shape back out" do
    metadata =
      [%{"name" => "TV-MA", "country" => "usa"}]
      |> transform()
      |> MediaMetadata.from_api_response(:tv_show, "12345")

    assert metadata.content_rating == "TV-MA"
  end

  test "prefers US over another country, matching TMDB parsing" do
    metadata =
      [
        %{"name" => "15", "country" => "gbr"},
        %{"name" => "TV-14", "country" => "usa"}
      ]
      |> transform()
      |> MediaMetadata.from_api_response(:tv_show, "12345")

    assert metadata.content_rating == "TV-14"
  end

  test "falls back to the only rating present when neither US nor GB appear" do
    metadata =
      [%{"name" => "16", "country" => "deu"}]
      |> transform()
      |> MediaMetadata.from_api_response(:tv_show, "12345")

    assert metadata.content_rating == "16"
  end

  test "emits nil when TVDB reports no ratings" do
    assert transform(nil)["content_ratings"] == nil
    assert transform([])["content_ratings"] == %{"results" => []}
  end

  # "ind" (India) is not one of the 19 codes in @tvdb_country_codes, so this
  # exercises the String.upcase/1 passthrough in tvdb_country_to_iso/1 rather
  # than a table hit. That passthrough is deliberate: an unmapped code still
  # reaches parse_content_rating/2's first-non-blank fallback instead of being
  # dropped, and nothing else in this file proves that path is alive.
  test "passes through an unmapped country code upcased instead of dropping it" do
    result = transform([%{"name" => "U/A 16+", "country" => "ind"}])

    assert %{"content_ratings" => %{"results" => [entry]}} = result
    assert entry["iso_3166_1"] == "IND"
    assert entry["rating"] == "U/A 16+"

    metadata =
      [%{"name" => "U/A 16+", "country" => "ind"}]
      |> transform()
      |> MediaMetadata.from_api_response(:tv_show, "12345")

    assert metadata.content_rating == "U/A 16+"
  end
end
