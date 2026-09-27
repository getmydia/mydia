defmodule Mydia.Metadata.ImageUrlTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.ImageUrl

  describe "backdrop_url/1" do
    # original is commonly 3840x2160, about 33 MB decoded. Every consumer
    # shows it blurred, dimmed or at most full-width, so w1280 is enough and
    # keeps the web player's GPU budget for posters.
    test "defaults to the w1280 TMDB size" do
      assert ImageUrl.backdrop_url("/abc.jpg") ==
               "https://image.tmdb.org/t/p/w1280/abc.jpg"
    end

    test "still honours an explicit size" do
      assert ImageUrl.backdrop_url("/abc.jpg", "original") ==
               "https://image.tmdb.org/t/p/original/abc.jpg"
    end

    test "passes full URLs through untouched" do
      url = "https://artworks.thetvdb.com/backdrop.jpg"
      assert ImageUrl.backdrop_url(url) == url
    end
  end

  describe "poster_url/1" do
    test "stays at w500" do
      assert ImageUrl.poster_url("/abc.jpg") ==
               "https://image.tmdb.org/t/p/w500/abc.jpg"
    end
  end
end
