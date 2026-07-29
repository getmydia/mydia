defmodule Mydia.Metadata.Structs.CollectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.{Collection, CollectionPart}

  defp body do
    %{
      "id" => 1241,
      "name" => "Harry Potter Collection",
      "overview" => "A wizarding saga.",
      "poster_path" => "/eVPs.jpg",
      "backdrop_path" => "/kmEs.jpg",
      "parts" => [
        %{
          "id" => 671,
          "title" => "Harry Potter and the Philosopher's Stone",
          "original_title" => "Harry Potter and the Philosopher's Stone",
          "overview" => "Harry discovers he is a wizard.",
          "release_date" => "2001-11-16",
          "poster_path" => "/wuMc.jpg",
          "backdrop_path" => "/hzii.jpg",
          "vote_average" => 7.9
        },
        %{
          "id" => 672,
          "title" => "Harry Potter and the Chamber of Secrets",
          "release_date" => "2002-11-13",
          "poster_path" => "/sdEO.jpg"
        }
      ]
    }
  end

  test "parses the collection and its parts" do
    collection = Collection.from_api_response(body())

    assert collection.provider_id == "1241"
    assert collection.name == "Harry Potter Collection"
    assert collection.overview == "A wizarding saga."
    assert collection.poster_path == "/eVPs.jpg"
    assert collection.backdrop_path == "/kmEs.jpg"
    assert [%CollectionPart{} = first, %CollectionPart{} = second] = collection.parts

    assert first.provider_id == "671"
    assert first.title == "Harry Potter and the Philosopher's Stone"
    assert first.release_date == ~D[2001-11-16]
    assert first.vote_average == 7.9

    assert second.provider_id == "672"
    assert second.release_date == ~D[2002-11-13]
    assert second.vote_average == nil
  end

  test "handles a missing parts key" do
    collection = Collection.from_api_response(Map.delete(body(), "parts"))
    assert collection.parts == []
  end

  test "handles an empty parts list" do
    collection = Collection.from_api_response(Map.put(body(), "parts", []))
    assert collection.parts == []
  end

  test "tolerates a part with no release date" do
    part_without_date = %{"id" => 999, "title" => "Untitled Sequel"}
    collection = Collection.from_api_response(Map.put(body(), "parts", [part_without_date]))

    assert [%CollectionPart{provider_id: "999", release_date: nil}] = collection.parts
  end

  test "tolerates a malformed release date" do
    part = %{"id" => 999, "title" => "Untitled Sequel", "release_date" => ""}
    collection = Collection.from_api_response(Map.put(body(), "parts", [part]))

    assert [%CollectionPart{release_date: nil}] = collection.parts
  end
end
