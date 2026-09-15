defmodule Mydia.Media.EpisodePlaceholderTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.EpisodePlaceholder

  describe "title?/1" do
    test "recognises every stand-in form the providers send" do
      for value <- [
            nil,
            "",
            "   ",
            "TBA",
            "TBA ",
            "tba",
            "TBD",
            "TBC",
            "Episode 8",
            "episode 12",
            "Episode #3",
            "Episode8"
          ] do
        assert EpisodePlaceholder.title?(value), "expected #{inspect(value)} to be a placeholder"
      end
    end

    test "leaves real titles alone, including ones built from the same words" do
      for value <- [
            "Harbor Lights",
            "Episode of the Lost Lantern",
            "TBA Means Tomorrow",
            "The Eighth Episode",
            "Episode 8: Homecoming"
          ] do
        refute EpisodePlaceholder.title?(value), "expected #{inspect(value)} to be a real title"
      end
    end
  end

  describe "overview?/1" do
    test "treats missing and stand-in overviews as placeholders" do
      for value <- [nil, "", "TBC", " tba "] do
        assert EpisodePlaceholder.overview?(value)
      end
    end

    test "a real overview, or one that only looks like a numbered title, is not a placeholder" do
      refute EpisodePlaceholder.overview?("The lighthouse keeper finds a letter.")
      refute EpisodePlaceholder.overview?("Episode 8")
    end
  end

  describe "still?/1" do
    test "only a missing or blank path is a placeholder" do
      assert EpisodePlaceholder.still?(nil)
      assert EpisodePlaceholder.still?("")
      refute EpisodePlaceholder.still?("/still.jpg")
    end
  end

  describe "title_change?/2" do
    test "a placeholder replaced by a real title is a change" do
      assert EpisodePlaceholder.title_change?("TBA ", "Harbor Lights")
      assert EpisodePlaceholder.title_change?(nil, "Harbor Lights")
    end

    test "a real title renamed to another real title is a change" do
      assert EpisodePlaceholder.title_change?("Harbor Lights", "Harbor Lights (Part 1)")
    end

    test "whitespace-only differences and placeholder swaps are not changes" do
      refute EpisodePlaceholder.title_change?("Harbor Lights", "Harbor Lights ")
      refute EpisodePlaceholder.title_change?("Episode 8", "TBA")
      refute EpisodePlaceholder.title_change?("Harbor Lights", nil)
    end
  end
end
