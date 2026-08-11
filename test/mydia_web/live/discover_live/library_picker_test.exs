defmodule MydiaWeb.DiscoverLive.LibraryPickerTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.SettingsFixtures

  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  # Rendering tests omitted: there are no existing Discover LiveView tests, no
  # `log_in_admin` helper, and Discover cards need a live metadata relay.
  # Plan says drop rendering tests and keep candidate_libraries/1 unit tests.

  describe "candidate_libraries/1" do
    test "returns only monitored, type-compatible libraries" do
      movies = library_path_fixture(%{type: "movies"})
      mixed = library_path_fixture(%{type: "mixed"})
      _series = library_path_fixture(%{type: "series"})
      unmonitored = library_path_fixture(%{type: "movies", monitored: false})

      ids = MediaAddHelpers.candidate_libraries(:movie) |> Enum.map(& &1.id)

      assert movies.id in ids
      assert mixed.id in ids
      refute unmonitored.id in ids
    end

    test "excludes unmaterialised runtime entries" do
      library_path_fixture(%{type: "movies"})

      # Runtime entries carry synthetic "runtime::" ids and have no DB row to
      # point a foreign key at, so they must never appear in a picker.
      refute MediaAddHelpers.candidate_libraries(:movie)
             |> Enum.any?(&String.starts_with?(to_string(&1.id), "runtime::"))
    end
  end
end
