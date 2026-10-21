defmodule Mydia.ImportCandidates.QueueErrorsTest do
  use ExUnit.Case, async: true

  alias Mydia.ImportCandidates.QueueErrors
  alias Mydia.Library.ImportCandidate
  alias Mydia.Library.MediaFile

  defp candidate(season, episodes),
    do: %ImportCandidate{parsed_info: %{"season" => season, "episodes" => episodes}}

  test "formats terminal refusals" do
    assert QueueErrors.message(:no_match) == "No provider match to import from."

    assert QueueErrors.message({:duplicate_path, "lp", "a.mkv"}) ==
             "A file at this path is already in the library."

    assert QueueErrors.message(:unresolved_episode) =~ "Couldn't tell which episode"
    assert QueueErrors.message(:implausible) =~ "far past the show's known episodes"

    assert QueueErrors.message({:incompatible_media_type, "movie", "tv_show"}) ==
             "This file's type doesn't match the matched title (movie or show)."
  end

  test "formats a changeset with field prefixes" do
    changeset =
      %MediaFile{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:relative_path, "can't be blank")

    assert QueueErrors.message(changeset) ==
             "This file can't be added to the library: relative_path can't be blank"
  end

  describe "file_message/2" do
    test "a special the provider doesn't list names it as a special" do
      assert QueueErrors.file_message(:implausible, candidate(0, [3])) ==
               "S00E03 isn't in this show's specials yet. " <>
                 "If the metadata provider lists it, refresh the show and accept again."
    end

    test "a repeated episode number renders as a single episode" do
      assert QueueErrors.file_message(:implausible, candidate(0, [1, 1])) ==
               "S00E01 isn't in this show's specials yet. " <>
                 "If the metadata provider lists it, refresh the show and accept again."
    end

    test "an out-of-range episode names the coordinate" do
      assert QueueErrors.file_message(:implausible, candidate(14, [40])) ==
               "S14E40 is far past this show's known episodes, so it wasn't created. " <>
                 "Check the season and episode."
    end

    test "a multi-episode file shows its range" do
      assert QueueErrors.file_message(:unresolved_episode, candidate(1, [1, 2])) ==
               "S01E01-E02 isn't in this show's episode list."
    end

    test "a file with no coordinate asks for one" do
      assert QueueErrors.file_message(:unresolved_episode, candidate(nil, [])) ==
               "No season and episode number. Set them on this row."

      assert QueueErrors.file_message(:unresolved_episode, %ImportCandidate{parsed_info: nil}) ==
               "No season and episode number. Set them on this row."
    end

    test "a season with no episode asks only for the episode" do
      assert QueueErrors.file_message(:unresolved_episode, candidate(2, [])) ==
               "S02 has no episode number. Set it on this row."

      assert QueueErrors.file_message(:implausible, candidate(2, ["x"])) ==
               "S02 has no episode number. Set it on this row."
    end

    test "episodes with no season ask only for the season" do
      assert QueueErrors.file_message(:unresolved_episode, candidate(nil, [3])) ==
               "No season number. Set it on this row."
    end

    test "other reasons fall back to message/1" do
      assert QueueErrors.file_message({:duplicate_path, "lp", "a.mkv"}, candidate(1, [1])) ==
               QueueErrors.message({:duplicate_path, "lp", "a.mkv"})
    end
  end

  test "the group message for a group where nothing imported" do
    assert QueueErrors.message({:no_file_imported, []}) ==
             "No file in this group could be imported."
  end
end
