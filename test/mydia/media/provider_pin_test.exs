defmodule Mydia.Media.ProviderPinTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{FixMatch, MediaItem, ProviderSwitch}
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  # A show whose files live in a library with the given TV provider.
  defp show_in_library(library_provider, attrs) do
    library = library_path_fixture(%{type: "series", tv_metadata_source: library_provider})
    item = media_item_fixture(Map.merge(%{type: "tv_show", title: "Lantern Harbor"}, attrs))
    episode = episode_fixture(%{media_item_id: item.id})
    media_file_fixture(%{episode_id: episode.id, library_path_id: library.id})
    Repo.get!(MediaItem, item.id)
  end

  describe "pin_for/2" do
    test "pins only when the provider differs from a known library provider" do
      assert ProviderSwitch.pin_for(:tmdb, :tvdb)
      assert ProviderSwitch.pin_for(:tvdb, :tmdb)
      refute ProviderSwitch.pin_for(:tvdb, :tvdb)
      refute ProviderSwitch.pin_for(:tmdb, :tmdb)
      refute ProviderSwitch.pin_for(:tmdb, nil)
    end
  end

  describe "provider_refresh_decision/1" do
    test "an unpinned TMDB show in a TVDB library is re-identified" do
      item = show_in_library(:tvdb, %{tmdb_id: 70_101, metadata_source: :tmdb})
      assert ProviderSwitch.provider_refresh_decision(item) == {:reidentify, :tvdb}
    end

    test "a pinned TMDB show in a TVDB library is re-fetched in place" do
      item =
        show_in_library(:tvdb, %{
          tmdb_id: 70_102,
          metadata_source: :tmdb,
          metadata_source_pinned: true
        })

      assert ProviderSwitch.provider_refresh_decision(item) == :refetch
    end
  end

  describe "FixMatch.provider_for/1" do
    test "a pinned show searches its own provider, not the library's" do
      item =
        show_in_library(:tvdb, %{
          tmdb_id: 70_103,
          metadata_source: :tmdb,
          metadata_source_pinned: true
        })

      assert FixMatch.provider_for(item) == :tmdb
    end

    test "an unpinned show searches the library's provider" do
      item = show_in_library(:tvdb, %{tmdb_id: 70_104, metadata_source: :tmdb})
      assert FixMatch.provider_for(item) == :tvdb
    end
  end

  describe "adopt_provider_switch/5 writes the pin" do
    test "switching onto the non-library provider pins the show" do
      item = show_in_library(:tvdb, %{tvdb_id: 70_105, metadata_source: :tvdb})
      candidate = %{provider_id: MetadataStubProvider.series_tmdb_id(), provider: :tmdb}

      assert {:ok, updated} =
               ProviderSwitch.adopt_provider_switch(Scope.system(), item, candidate, :tmdb)

      assert updated.metadata_source == :tmdb
      assert updated.metadata_source_pinned
    end

    test "switching back onto the library provider clears the pin" do
      item =
        show_in_library(:tvdb, %{
          tmdb_id: 70_106,
          metadata_source: :tmdb,
          metadata_source_pinned: true
        })

      candidate = %{provider_id: MetadataStubProvider.series_tvdb_id(), provider: :tvdb}

      assert {:ok, updated} =
               ProviderSwitch.adopt_provider_switch(Scope.system(), item, candidate, :tvdb)

      assert updated.metadata_source == :tvdb
      refute updated.metadata_source_pinned
    end
  end
end
