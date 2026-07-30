defmodule Mydia.Metadata.Structs.MediaMetadataCollectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.MediaMetadata

  test "parses belongs_to_collection from a movie response" do
    body = %{
      "id" => 671,
      "title" => "Harry Potter and the Philosopher's Stone",
      "release_date" => "2001-11-16",
      "credits" => %{"cast" => [], "crew" => []},
      "belongs_to_collection" => %{
        "id" => 1241,
        "name" => "Harry Potter Collection",
        "poster_path" => "/eVPs.jpg",
        "backdrop_path" => "/kmEs.jpg"
      }
    }

    metadata = MediaMetadata.from_api_response(body, :movie, "671")

    assert metadata.collection_id == 1241
    assert metadata.collection_name == "Harry Potter Collection"
  end

  test "leaves the collection pointer nil when the key is absent" do
    body = %{
      "id" => 603,
      "title" => "The Matrix",
      "release_date" => "1999-03-30",
      "credits" => %{"cast" => [], "crew" => []}
    }

    metadata = MediaMetadata.from_api_response(body, :movie, "603")

    assert metadata.collection_id == nil
    assert metadata.collection_name == nil
  end

  test "leaves the collection pointer nil when the key is explicitly null" do
    body = %{
      "id" => 603,
      "title" => "The Matrix",
      "release_date" => "1999-03-30",
      "credits" => %{"cast" => [], "crew" => []},
      "belongs_to_collection" => nil
    }

    metadata = MediaMetadata.from_api_response(body, :movie, "603")

    assert metadata.collection_id == nil
  end

  test "leaves the collection pointer nil for TV shows" do
    body = %{
      "id" => 1396,
      "name" => "Breaking Bad",
      "first_air_date" => "2008-01-20",
      "credits" => %{"cast" => [], "crew" => []}
    }

    metadata = MediaMetadata.from_api_response(body, :tv_show, "1396")

    assert metadata.collection_id == nil
    assert metadata.collection_name == nil
  end
end
