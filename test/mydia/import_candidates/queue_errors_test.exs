defmodule Mydia.ImportCandidates.QueueErrorsTest do
  use ExUnit.Case, async: true

  alias Mydia.ImportCandidates.QueueErrors
  alias Mydia.Library.MediaFile

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
end
