defmodule Mydia.Library.ReleaseParser.EpisodeTitleTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.EpisodeTitle

  describe "extract/1" do
    test "recovers a dash-separated episode title" do
      assert EpisodeTitle.extract(
               "On joue! avec Biscuit et Cassonade (2022) - S04E03 - La chorale.mkv"
             ) == "La chorale"
    end

    test "keeps accented multi-word titles intact" do
      assert EpisodeTitle.extract("Show (2022) - S04E01 - La soirée pyjama.mkv") ==
               "La soirée pyjama"
    end

    test "returns nil for a scene release carrying no title" do
      assert EpisodeTitle.extract("Show.S04E01.1080p.WEB-DL.x264-GROUP.mkv") == nil
    end

    test "stops at the first release-metadata token" do
      assert EpisodeTitle.extract("Show - S04E01 - La chorale - 1080p.WEB-DL.mkv") ==
               "La chorale"
    end

    test "returns nil when nothing follows the marker" do
      assert EpisodeTitle.extract("Show - S04E01.mkv") == nil
    end

    test "returns nil when there is no episode marker" do
      assert EpisodeTitle.extract("Some Movie (2019) 1080p.mkv") == nil
    end

    test "returns nil for nil input" do
      assert EpisodeTitle.extract(nil) == nil
    end

    test "drops a residual episode fragment when '.' splits the marker" do
      assert EpisodeTitle.extract("Show.S04.E01.Title.mkv") == "Title"
    end

    test "drops a residual episode fragment when whitespace splits the marker" do
      assert EpisodeTitle.extract("Show S04 E01 - Title.mkv") == "Title"
    end

    test "drops a residual fragment from a multi-episode marker" do
      assert EpisodeTitle.extract("Show.S02E05.E06.Title.mkv") == "Title"
    end

    test "keeps a trailing exclamation mark that belongs to the title" do
      assert EpisodeTitle.extract("Show - S04E01 - Surprise!.mkv") == "Surprise!"
    end

    test "keeps a trailing question mark that belongs to the title" do
      assert EpisodeTitle.extract("Show - S04E01 - Who Are You?.mkv") == "Who Are You?"
    end

    test "returns nil when only punctuation follows the marker" do
      assert EpisodeTitle.extract("Show - S04E01 - !!!.mkv") == nil
    end
  end
end
