defmodule Mydia.Upgrades.ReasonsTest do
  use ExUnit.Case, async: true

  alias Mydia.Upgrades.Reasons

  test "decode reads known reasons in a fixed order and defaults to quality" do
    assert Reasons.decode(["language", "quality"]) == [:quality, :language]
    assert Reasons.decode(["language"]) == [:language]
    assert Reasons.decode(["bogus"]) == [:quality]
    assert Reasons.decode([]) == [:quality]
    assert Reasons.decode(nil) == [:quality]
  end

  test "encode writes strings, quality first, and round-trips" do
    assert Reasons.encode([:language, :quality]) == ["quality", "language"]
    assert Reasons.decode(Reasons.encode([:language])) == [:language]
  end

  test "each reason owns its own bucket per kind" do
    assert Reasons.buckets(:movie, [:language, :quality]) == [
             "movie_upgrade",
             "movie_language_upgrade"
           ]

    assert Reasons.bucket(:episode, :language) == "episode_language_upgrade"
    assert Reasons.bucket(:season, :quality) == "season_upgrade"
    assert Reasons.bucket(:season, :language) == "season_language_upgrade"
  end
end
