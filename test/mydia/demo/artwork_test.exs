defmodule Mydia.Demo.ArtworkTest do
  use ExUnit.Case, async: true

  alias Mydia.Demo.Artwork

  test "posters carry the title text" do
    assert Artwork.svg("Lanternfall Station", :poster) =~ "<text"
  end

  test "backdrops carry no text, so apps do not show a ghost title" do
    svg = Artwork.svg("Lanternfall Station", :backdrop)

    refute svg =~ "<text"
    refute svg =~ "Lanternfall"
  end
end
