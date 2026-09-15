defmodule Mydia.Upgrades.FileLanguagesTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Upgrades.FileLanguages

  defp file_with(streams), do: %MediaFile{metadata: %FileMetadata{streams: streams}}
  defp audio(index, language), do: %StreamInfo{index: index, type: :audio, language: language}

  describe "detect/1" do
    test "reads canonical codes from the audio streams, sorted and deduplicated" do
      file =
        file_with([
          %StreamInfo{index: 0, type: :video},
          audio(1, "jpn"),
          audio(2, "eng"),
          audio(3, "ja")
        ])

      assert FileLanguages.detect(file) == {:known, ["en", "ja"]}
    end

    test "ignores subtitle streams" do
      file = file_with([audio(1, "jpn"), %StreamInfo{index: 2, type: :subtitle, language: "eng"}])
      assert FileLanguages.detect(file) == {:known, ["ja"]}
    end

    test "an undetermined or untagged stream contributes nothing" do
      assert FileLanguages.detect(file_with([audio(1, "und"), audio(2, "rus")])) ==
               {:known, ["ru"]}

      assert FileLanguages.detect(file_with([audio(1, "und"), audio(2, nil)])) == :unknown
    end

    test "a file whose streams were never captured is unknown" do
      assert FileLanguages.detect(%MediaFile{metadata: %FileMetadata{streams: nil}}) == :unknown
      assert FileLanguages.detect(%MediaFile{metadata: nil}) == :unknown
      assert FileLanguages.detect(nil) == :unknown
    end
  end

  describe "gap?/2" do
    setup do
      %{
        server: AudioLanguagePolicy.new(["original", "en"], :server, "ja"),
        show: AudioLanguagePolicy.new(["en"], :show, "ja")
      }
    end

    test "the server default only flags a file carrying none of its languages", %{server: server} do
      refute FileLanguages.gap?(server, {:known, ["ja"]})
      refute FileLanguages.gap?(server, {:known, ["en"]})
      assert FileLanguages.gap?(server, {:known, ["it"]})
    end

    test "a show list flags anything without its first language", %{show: show} do
      assert FileLanguages.gap?(show, {:known, ["ja"]})
      refute FileLanguages.gap?(show, {:known, ["en", "ja"]})
    end

    test "unknown languages and an empty or missing policy never have a gap", %{show: show} do
      refute FileLanguages.gap?(show, :unknown)
      refute FileLanguages.gap?(AudioLanguagePolicy.new([], :show, "ja"), {:known, ["it"]})
      refute FileLanguages.gap?(nil, {:known, ["it"]})
    end
  end

  describe "none_preferred?/2" do
    test "is true only for known languages outside the policy" do
      policy = AudioLanguagePolicy.new(["original", "en"], :server, "ja")

      assert FileLanguages.none_preferred?(policy, {:known, ["ru"]})
      refute FileLanguages.none_preferred?(policy, {:known, ["en"]})
      refute FileLanguages.none_preferred?(policy, :unknown)
      refute FileLanguages.none_preferred?(nil, {:known, ["ru"]})
    end
  end

  describe "compare/3" do
    setup do
      %{policy: AudioLanguagePolicy.new(["en"], :show, "ja")}
    end

    test "ranks a candidate against the current file", %{policy: policy} do
      assert FileLanguages.compare(policy, {:known, ["ja"]}, {:known, ["en", "ja"]}) == :better
      assert FileLanguages.compare(policy, {:known, ["en"]}, {:known, ["ja"]}) == :worse
      assert FileLanguages.compare(policy, {:known, ["en"]}, {:known, ["en", "ja"]}) == :equal
    end

    test "anything unknown, or no preference, compares equal", %{policy: policy} do
      assert FileLanguages.compare(policy, :unknown, {:known, ["en"]}) == :equal
      assert FileLanguages.compare(policy, {:known, ["ja"]}, :unknown) == :equal
      assert FileLanguages.compare(nil, {:known, ["ja"]}, {:known, ["en"]}) == :equal
    end
  end

  test "to_list/1 flattens for event metadata" do
    assert FileLanguages.to_list({:known, ["en", "ja"]}) == ["en", "ja"]
    assert FileLanguages.to_list(:unknown) == []
  end
end
