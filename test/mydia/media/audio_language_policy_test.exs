defmodule Mydia.Media.AudioLanguagePolicyTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.AudioLanguagePolicy

  describe "new/3" do
    test "resolves the original sentinel and keeps order" do
      policy = AudioLanguagePolicy.new(["original", "en"], :server, "jpn")

      assert policy.languages == ["ja", "en"]
      assert policy.source == :server
      assert policy.original_language == "ja"
    end

    test "drops the sentinel when the original language is unknown" do
      assert AudioLanguagePolicy.new(["original", "en"], :server, nil).languages == ["en"]
    end

    test "normalizes codes and removes duplicates, keeping the first" do
      policy = AudioLanguagePolicy.new(["ENG", "ja", "en", "original"], :show, "ja")
      assert policy.languages == ["en", "ja"]
    end

    test "ignores blanks and non-strings" do
      assert AudioLanguagePolicy.new(["", nil, "und", "fr"], :show, nil).languages == ["fr"]
    end
  end

  describe "rank/2 and matches/2" do
    setup do
      %{policy: AudioLanguagePolicy.new(["original", "en"], :server, "ja")}
    end

    test "dual audio ranks first with two matches", %{policy: policy} do
      assert AudioLanguagePolicy.rank(policy, ["en", "ja"]) == 0
      assert AudioLanguagePolicy.matches(policy, ["en", "ja"]) == 2
    end

    test "original-only ranks first with one match", %{policy: policy} do
      assert AudioLanguagePolicy.rank(policy, ["ja"]) == 0
      assert AudioLanguagePolicy.matches(policy, ["ja"]) == 1
    end

    test "an English dub ranks second", %{policy: policy} do
      assert AudioLanguagePolicy.rank(policy, ["en"]) == 1
    end

    test "a release carrying no preferred language ranks last", %{policy: policy} do
      assert AudioLanguagePolicy.rank(policy, ["it"]) == 2
      assert AudioLanguagePolicy.rank(policy, []) == 2
      assert AudioLanguagePolicy.matches(policy, ["it"]) == 0
    end

    test "an English-first override puts Japanese-only last" do
      policy = AudioLanguagePolicy.new(["en"], :show, "ja")

      assert AudioLanguagePolicy.rank(policy, ["en", "ja"]) == 0
      assert AudioLanguagePolicy.rank(policy, ["en"]) == 0
      assert AudioLanguagePolicy.rank(policy, ["ja"]) == 1
    end

    test "no policy, or an empty one, ranks everything equally" do
      assert AudioLanguagePolicy.rank(nil, ["it"]) == 0
      assert AudioLanguagePolicy.matches(nil, ["it"]) == 0

      empty = AudioLanguagePolicy.new([], :server, "ja")
      assert AudioLanguagePolicy.rank(empty, ["it"]) == 0
    end
  end

  describe "event_fields/1" do
    test "records the resolved list and its source" do
      policy = AudioLanguagePolicy.new(["en"], :show, "ja")

      assert AudioLanguagePolicy.event_fields(policy) == %{
               "audio_preference" => ["en"],
               "audio_preference_source" => "show"
             }
    end

    test "is empty without a policy" do
      assert AudioLanguagePolicy.event_fields(nil) == %{}
    end
  end
end
