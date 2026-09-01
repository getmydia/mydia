defmodule Mydia.Media.AttrsFromMetadataTest do
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias Mydia.Media.AddDefaults
  alias Mydia.Media.AttrsFromMetadata

  defp metadata do
    %{
      title: "Quiet Harbour",
      original_title: "Quiet Harbour",
      year: 2021,
      release_date: "2021-04-02",
      provider_id: "9001",
      provider: :tmdb
    }
  end

  describe "from_metadata/3" do
    test "carries the resolved quality profile and library path" do
      profile = quality_profile_fixture()
      Mydia.Settings.set_default_quality_profile(profile.id)
      library = library_path_fixture(%{type: :movies})
      Mydia.Settings.set_default_library(library, :movies)

      attrs = AttrsFromMetadata.from_metadata(metadata(), :movie)

      assert attrs.quality_profile_id == profile.id
      assert attrs.library_path_id == library.id
    end

    test "carries the resolved monitored flag" do
      defaults = %AddDefaults{
        monitored: false,
        season_monitoring: "all",
        search_on_add: false,
        library_path_id: nil,
        quality_profile_id: nil
      }

      attrs = AttrsFromMetadata.from_metadata(metadata(), :movie, defaults: defaults)

      assert attrs.monitored == false
    end

    test "stores tmdb_id for a movie" do
      attrs = AttrsFromMetadata.from_metadata(metadata(), :movie)

      assert attrs.tmdb_id == "9001"
      assert attrs.type == "movie"
    end

    test "stores tvdb_id for a tvdb-sourced show" do
      meta = %{metadata() | provider: :tvdb}

      attrs = AttrsFromMetadata.from_metadata(meta, :tv_show)

      assert attrs.tvdb_id == "9001"
      assert attrs.type == "tv_show"
    end
  end

  describe "from_parsed/3" do
    test "prefers metadata title over the parsed title" do
      parsed = %{type: :movie, title: "quiet.harbour.2021", year: 2021}

      attrs = AttrsFromMetadata.from_parsed(parsed, metadata())

      assert attrs.title == "Quiet Harbour"
    end

    test "falls back to the parsed title when metadata has none" do
      parsed = %{type: :movie, title: "Parsed Fallback", year: 2021}
      meta = %{metadata() | title: nil}

      attrs = AttrsFromMetadata.from_parsed(parsed, meta)

      assert attrs.title == "Parsed Fallback"
    end

    test "carries the resolved library path" do
      library = library_path_fixture(%{type: :movies})
      Mydia.Settings.set_default_library(library, :movies)
      parsed = %{type: :movie, title: "quiet.harbour.2021", year: 2021}

      attrs = AttrsFromMetadata.from_parsed(parsed, metadata())

      assert attrs.library_path_id == library.id
    end
  end
end
