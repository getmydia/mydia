defmodule Mydia.Media.ContentRatingTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.ContentRating

  describe "min_age/1 US film ratings" do
    test "maps the MPA ladder" do
      assert ContentRating.min_age("G") == 0
      assert ContentRating.min_age("PG") == 8
      assert ContentRating.min_age("PG-13") == 13
      assert ContentRating.min_age("R") == 17
      assert ContentRating.min_age("NC-17") == 18
    end
  end

  describe "min_age/1 US television ratings" do
    test "maps the TV Parental Guidelines ladder" do
      assert ContentRating.min_age("TV-Y") == 0
      assert ContentRating.min_age("TV-G") == 0
      assert ContentRating.min_age("TV-Y7") == 7
      assert ContentRating.min_age("TV-PG") == 8
      assert ContentRating.min_age("TV-14") == 14
      assert ContentRating.min_age("TV-MA") == 17
    end
  end

  describe "min_age/1 UK ratings" do
    test "maps the BBFC ladder" do
      assert ContentRating.min_age("U") == 0
      assert ContentRating.min_age("12") == 12
      assert ContentRating.min_age("12A") == 12
      assert ContentRating.min_age("15") == 15
      assert ContentRating.min_age("18") == 18
      assert ContentRating.min_age("R18") == 18
    end
  end

  describe "min_age/1 bare numeric certifications" do
    test "maps a plain age to itself" do
      assert ContentRating.min_age("6") == 6
      assert ContentRating.min_age("16") == 16
    end

    test "rejects a number that cannot be a viewer age" do
      assert ContentRating.min_age("1984") == nil
      assert ContentRating.min_age("-3") == nil
    end
  end

  describe "min_age/1 normalization" do
    test "ignores case and surrounding whitespace" do
      assert ContentRating.min_age("  pg-13 ") == 13
      assert ContentRating.min_age("tv-ma") == 17
    end
  end

  describe "min_age/1 unrecognized input" do
    test "returns nil so an active limit fails closed" do
      assert ContentRating.min_age(nil) == nil
      assert ContentRating.min_age("") == nil
      assert ContentRating.min_age("NOT RATED") == nil
      assert ContentRating.min_age("Unrated") == nil
      assert ContentRating.min_age(:pg) == nil
    end
  end

  describe "thresholds/0" do
    test "returns the ladder an admin picks from, ascending" do
      ages = Enum.map(ContentRating.thresholds(), fn {_label, age} -> age end)
      assert ages == [0, 7, 12, 14, 16, 18]
    end
  end
end
