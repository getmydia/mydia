defmodule Mydia.Indexers.Cardigann.LinksTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.CardigannDefinition.Parsed

  test "returns links first, then legacylinks" do
    parsed = %Parsed{
      links: ["https://a.example.com/", "https://b.example.com"],
      legacylinks: ["https://old.example.com/"]
    }

    assert Links.candidates(parsed) == [
             "https://a.example.com",
             "https://b.example.com",
             "https://old.example.com"
           ]
  end

  test "trims trailing slashes" do
    parsed = %Parsed{links: ["https://a.example.com///"], legacylinks: []}
    assert Links.candidates(parsed) == ["https://a.example.com"]
  end

  test "removes duplicates keeping first position" do
    parsed = %Parsed{
      links: ["https://a.example.com/", "https://b.example.com/"],
      legacylinks: ["https://a.example.com", "https://c.example.com/"]
    }

    assert Links.candidates(parsed) == [
             "https://a.example.com",
             "https://b.example.com",
             "https://c.example.com"
           ]
  end

  test "drops blanks and non-binaries" do
    parsed = %Parsed{links: ["https://a.example.com/", "", "   ", nil], legacylinks: [123]}
    assert Links.candidates(parsed) == ["https://a.example.com"]
  end

  test "returns an empty list when there is nothing to use" do
    assert Links.candidates(%Parsed{links: [], legacylinks: []}) == []
    assert Links.candidates(%Parsed{links: nil, legacylinks: nil}) == []
  end
end
