defmodule Mydia.MediaTest do
  use Mydia.DataCase

  alias Mydia.Media

  describe "media_items" do
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    @invalid_attrs %{type: nil, title: nil}

    test "create_media_item/2 accepts an explicit library_path_id" do
      library = library_path_fixture(%{type: "movies"})

      {:ok, item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Targeted Movie",
          year: 2024,
          library_path_id: library.id
        })

      assert item.library_path_id == library.id
    end

    test "deleting a library path nils the media item's target instead of failing" do
      library = library_path_fixture(%{type: "movies"})

      {:ok, item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Orphaned Target",
          year: 2024,
          library_path_id: library.id
        })

      {:ok, _} = Mydia.Settings.delete_library_path(library)

      assert Mydia.Repo.get!(Mydia.Media.MediaItem, item.id).library_path_id == nil
    end

    test "list_media_items/0 returns all media items" do
      media_item = media_item_fixture()
      assert Media.list_media_items() == [media_item]
    end

    test "get_media_item!/1 returns the media item with given id" do
      media_item = media_item_fixture()
      assert Media.get_media_item!(media_item.id) == media_item
    end

    test "create_media_item/1 with valid data creates a media item" do
      valid_attrs = %{
        type: "movie",
        title: "Test Movie",
        year: 2024,
        tmdb_id: 12345,
        monitored: true
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(valid_attrs)
      assert media_item.type == "movie"
      assert media_item.title == "Test Movie"
      assert media_item.year == 2024
      assert media_item.tmdb_id == 12345
      assert media_item.monitored == true
    end

    test "create_media_item/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_media_item(@invalid_attrs)
    end

    test "create_media_item/1 requires year for movies" do
      attrs_without_year = %{
        type: "movie",
        title: "Test Movie",
        tmdb_id: 12345,
        monitored: true
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               Media.create_media_item(attrs_without_year)

      assert %{year: ["is required for movies"]} = errors_on(changeset)
    end

    test "create_media_item/1 allows tv_shows without year" do
      attrs_without_year = %{
        type: "tv_show",
        title: "Test Show",
        tmdb_id: 12345,
        monitored: true
      }

      assert {:ok, %MediaItem{} = media_item} =
               Media.create_media_item(attrs_without_year, skip_episode_refresh: true)

      assert media_item.type == "tv_show"
      assert media_item.title == "Test Show"
      assert media_item.year == nil
    end

    test "update_media_item/2 with valid data updates the media item" do
      media_item = media_item_fixture()
      update_attrs = %{title: "Updated Title", monitored: false}

      assert {:ok, %MediaItem{} = media_item} =
               Media.update_media_item(media_item, update_attrs)

      assert media_item.title == "Updated Title"
      assert media_item.monitored == false
    end

    test "delete_media_item/1 deletes the media item" do
      media_item = media_item_fixture()
      assert {:ok, %MediaItem{}, 0} = Media.delete_media_item(media_item)
      assert_raise Ecto.NoResultsError, fn -> Media.get_media_item!(media_item.id) end
    end

    test "change_media_item/1 returns a media item changeset" do
      media_item = media_item_fixture()
      assert %Ecto.Changeset{} = Media.change_media_item(media_item)
    end

    test "media items default to monitoring new seasons" do
      media_item = media_item_fixture(%{type: "tv_show"})

      assert media_item.monitor_new_seasons == :all
    end

    test "monitor_new_seasons is castable through the changeset" do
      media_item = media_item_fixture(%{type: "tv_show"})

      changeset = Mydia.Media.MediaItem.changeset(media_item, %{monitor_new_seasons: :none})

      assert Ecto.Changeset.get_change(changeset, :monitor_new_seasons) == :none
    end

    test "a new episode in an unmonitored season arrives unmonitored" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 3,
        episode_number: 1,
        monitored: true
      )

      {:ok, _count} = Media.update_season_monitoring(media_item.id, 3, false)

      # `upsert_episodes_from_season/3` calls `Map.from_struct/1` on each episode,
      # so these must be %EpisodeData{} structs, not plain maps. `season_data`
      # itself is only dot-accessed, so a plain map is fine there.
      season_data = %{
        season_number: 3,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 3,
            episode_number: 11,
            name: "New One",
            air_date: ~D[2026-09-01]
          }
        ]
      }

      {:ok, 1} =
        Media.upsert_episodes_from_season(media_item, season_data,
          monitor_new?: Media.should_monitor_new_episode?(media_item, 3)
        )

      new_episode = Media.get_episode_by_number(media_item.id, 3, 11)
      refute new_episode.monitored
    end

    test "apply_episode_monitoring/2 leaves the show row alone" do
      # Starts at :none so an accidental write to :all would be visible. The
      # earlier version of this test started at :all and asserted :all, which
      # passed no matter what the function did.
      media_item =
        media_item_fixture(%{type: "tv_show", monitored: true, monitor_new_seasons: :none})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        monitored: false
      )

      {:ok, count} = Media.apply_episode_monitoring(media_item, :all)

      assert count == 1
      assert Media.get_media_item!(media_item.id).monitor_new_seasons == :none
    end

    test "apply_episode_monitoring/2 returns an error for movies" do
      media_item = media_item_fixture(%{type: "movie"})

      assert {:error, {:invalid_type, _}} = Media.apply_episode_monitoring(media_item, :all)
    end

    test "set_monitor_new_seasons/2 is independent of the presets" do
      # The state the folded-in version could not express: keep everything I
      # have monitored, but do not chase seasons that show up later.
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})
      episode_fixture(media_item_id: media_item.id, season_number: 1, episode_number: 1)

      {:ok, _} = Media.apply_episode_monitoring(media_item, :all)
      {:ok, updated} = Media.set_monitor_new_seasons(media_item, :none)

      assert updated.monitor_new_seasons == :none
      assert Enum.all?(Media.list_episodes(media_item.id), & &1.monitored)
      refute Media.should_monitor_new_episode?(updated, 9)
      assert Media.should_monitor_new_episode?(updated, 1)
    end

    test "set_monitor_new_seasons/2 writes through a stale struct" do
      media_item = media_item_fixture(%{type: "tv_show", monitor_new_seasons: :all})

      {:ok, _} = Media.set_monitor_new_seasons(media_item, :none)
      # media_item is now stale, still holding :all. A changeset would see no
      # change and skip the write.
      {:ok, _} = Media.set_monitor_new_seasons(media_item, :all)

      assert Media.get_media_item!(media_item.id).monitor_new_seasons == :all
    end

    test "derive_monitoring_preset/1 says :none when nothing is monitored" do
      # Regression: :none was checked last and several partitions produce the
      # empty set, so a fully-aired show with nothing monitored read back as
      # "Future Episodes" and clicking "No Episodes" never showed "No Episodes".
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        air_date: ~D[2020-01-01]
      )

      {:ok, _} = Media.apply_episode_monitoring(media_item, :none)
      episodes = Media.list_episodes(media_item.id, preload: [:media_files])

      assert Media.derive_monitoring_preset(episodes) == :none
    end

    test "no preset sweeps in specials" do
      # Regression: :missing and :future had no season 0 guard, so a bulk apply
      # monitored fileless specials, which then left should_monitor_new_episode?
      # admitting every future special forever.
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})
      episode_fixture(media_item_id: media_item.id, season_number: 0, episode_number: 1)
      episode_fixture(media_item_id: media_item.id, season_number: 1, episode_number: 1)

      for preset <- Media.monitoring_presets() do
        {:ok, _} = Media.apply_episode_monitoring(media_item, preset)
        special = Media.get_episode_by_number(media_item.id, 0, 1)

        refute special.monitored, "#{preset} monitored a special"
      end
    end

    test "a TV show with an unknown preset reports the preset, not the type" do
      media_item = media_item_fixture(%{type: "tv_show"})

      assert {:error, {:invalid_preset, _}} =
               Media.apply_episode_monitoring(media_item, :first_season)
    end

    test "derive_monitoring_preset/1 reads the rows back, or says :custom" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})
      episode_fixture(media_item_id: media_item.id, season_number: 1, episode_number: 1)
      episode_fixture(media_item_id: media_item.id, season_number: 2, episode_number: 1)

      {:ok, _} = Media.apply_episode_monitoring(media_item, :all)
      episodes = Media.list_episodes(media_item.id, preload: [:media_files])
      assert Media.derive_monitoring_preset(episodes) == :all

      # A manual season toggle is exactly what used to leave the label lying.
      {:ok, _} = Media.update_season_monitoring(media_item.id, 2, false)
      episodes = Media.list_episodes(media_item.id, preload: [:media_files])
      assert Media.derive_monitoring_preset(episodes) == :custom
    end

    test "update_media_items_batch/2 rejects a nonexistent quality_profile_id" do
      media_item = media_item_fixture(%{type: "movie"})

      assert {:error, :not_found} =
               Media.update_media_items_batch([media_item.id], %{
                 quality_profile_id: Ecto.UUID.generate()
               })

      assert Media.get_media_item!(media_item.id).quality_profile_id == nil
    end

    test "update_media_items_batch/2 applies a valid quality_profile_id" do
      media_item = media_item_fixture(%{type: "movie"})
      profile = quality_profile_fixture()

      assert {:ok, 1} =
               Media.update_media_items_batch([media_item.id], %{
                 quality_profile_id: profile.id
               })

      assert Media.get_media_item!(media_item.id).quality_profile_id == profile.id
    end
  end

  # Nested describe is invalid in ExUnit. These live as siblings of "media_items"
  # with their own MediaFixtures import (allowed by the plan's global constraints).
  describe "new episode admission" do
    import Mydia.MediaFixtures

    test "an unmonitored show admits nothing" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: false})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        monitored: true
      )

      refute Media.should_monitor_new_episode?(media_item, 1)
    end

    test "a season with any monitored episode admits new episodes" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 3,
        episode_number: 1,
        monitored: false
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 3,
        episode_number: 2,
        monitored: true
      )

      assert Media.should_monitor_new_episode?(media_item, 3)
    end

    test "a fully unmonitored season admits nothing" do
      # This is the reported bug: unmonitoring season 3 must also stop future
      # episodes in season 3.
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 3,
        episode_number: 1,
        monitored: false
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 3,
        episode_number: 2,
        monitored: false
      )

      refute Media.should_monitor_new_episode?(media_item, 3)
    end

    test "a brand new season follows monitor_new_seasons: :all" do
      media_item =
        media_item_fixture(%{type: "tv_show", monitored: true, monitor_new_seasons: :all})

      assert Media.should_monitor_new_episode?(media_item, 4)
    end

    test "a brand new season follows monitor_new_seasons: :none" do
      media_item =
        media_item_fixture(%{type: "tv_show", monitored: true, monitor_new_seasons: :none})

      refute Media.should_monitor_new_episode?(media_item, 4)
    end

    test "a brand new specials season is never admitted" do
      media_item =
        media_item_fixture(%{type: "tv_show", monitored: true, monitor_new_seasons: :all})

      refute Media.should_monitor_new_episode?(media_item, 0)
    end

    test "an existing specials season with a monitored special is admitted" do
      media_item =
        media_item_fixture(%{type: "tv_show", monitored: true, monitor_new_seasons: :none})

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 0,
        episode_number: 1,
        monitored: true
      )

      assert Media.should_monitor_new_episode?(media_item, 0)
    end
  end

  describe "season_monitoring_state/1" do
    test "classifies all, partial, none, and empty" do
      all = [%Mydia.Media.Episode{monitored: true}, %Mydia.Media.Episode{monitored: true}]
      partial = [%Mydia.Media.Episode{monitored: true}, %Mydia.Media.Episode{monitored: false}]
      none = [%Mydia.Media.Episode{monitored: false}]

      assert Media.season_monitoring_state(all) == :all
      assert Media.season_monitoring_state(partial) == :partial
      assert Media.season_monitoring_state(none) == :none
      assert Media.season_monitoring_state([]) == :none
    end
  end

  describe "upsert_episodes_from_season/3 monitor_new? option" do
    import Mydia.MediaFixtures

    test "raises when :monitor_new? is omitted" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})
      season_data = %{season_number: 1, episodes: []}

      assert_raise KeyError, fn ->
        Media.upsert_episodes_from_season(media_item, season_data)
      end
    end

    test "upsert_episodes_from_season/3 persists absolute numbers and provider ids" do
      show = media_item_fixture(%{type: "tv_show", title: "Absolute"})

      season_data = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 52,
            absolute_number: 52,
            provider_episode_id: "6832458",
            name: "Whoever's Strongest Wins"
          }
        ]
      }

      {:ok, 1} = Media.upsert_episodes_from_season(show, season_data, monitor_new?: true)

      episode = Media.find_episode(show.id, 1, 52)
      assert episode.absolute_number == 52
      assert episode.provider_episode_id == "6832458"
    end

    test "upsert_episodes_from_season/3 moves an episode rather than duplicating it" do
      show = media_item_fixture(%{type: "tv_show", title: "Reordered"})

      official = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 52,
            absolute_number: 52,
            provider_episode_id: "6832458"
          }
        ]
      }

      {:ok, 1} = Media.upsert_episodes_from_season(show, official, monitor_new?: true)
      original_id = Media.find_episode(show.id, 1, 52).id

      # The same provider episode, presented under DVD ordering as S2E1.
      dvd = %Mydia.Metadata.Structs.SeasonData{
        season_number: 2,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 2,
            episode_number: 1,
            absolute_number: 52,
            provider_episode_id: "6832458"
          }
        ]
      }

      {:ok, 1} = Media.upsert_episodes_from_season(show, dvd, monitor_new?: true)

      assert Media.find_episode(show.id, 1, 52) == nil

      moved = Media.find_episode(show.id, 2, 1)
      assert moved.provider_episode_id == "6832458"

      # Same row moved in place, not deleted-and-recreated: an implementation
      # that dropped S1E52 and inserted a fresh S2E1 row would satisfy every
      # assertion above while destroying that row's file links, watch
      # history and monitored flag — the entire reason to key on provider id.
      assert moved.id == original_id
      assert length(Media.list_episodes(show.id)) == 1
    end

    test "upsert_episodes_from_season/3 does not retag a row already tagged with a different provider id" do
      show = media_item_fixture(%{type: "tv_show", title: "Renumbered"})

      original = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 52,
            provider_episode_id: "X"
          }
        ]
      }

      {:ok, 1} = Media.upsert_episodes_from_season(show, original, monitor_new?: true)

      # A genuinely different provider episode ("Y") arrives at the same
      # coordinates row "X" currently occupies — e.g. an upstream renumber
      # mid-season. The (season_number, episode_number) fallback must not
      # silently adopt "X"'s row and overwrite its identity with "Y": that
      # would permanently strand "X"'s file links and watch history under
      # the wrong episode the next time a payload moves "Y" elsewhere.
      renumbered = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 52,
            provider_episode_id: "Y"
          }
        ]
      }

      # The fallback refuses to adopt the tagged row, so "Y" falls to create,
      # which collides with the season/episode unique index ("X" still sits
      # there) and is discarded. Noisy and self-correcting via the returned
      # count, rather than silently transferring "X"'s identity to "Y".
      assert {:ok, 0} = Media.upsert_episodes_from_season(show, renumbered, monitor_new?: true)

      assert %{provider_episode_id: "X"} = Media.find_episode(show.id, 1, 52)
    end

    test "upsert_episodes_from_season/3 rejects a move onto coordinates another episode already occupies" do
      # KNOWN LIMITATION: a single-pass positional write cannot move an
      # episode onto coordinates a different episode currently occupies
      # without a transient unique-index collision. A later task in this
      # plan performs ordering switches through a dedicated two-pass remap
      # inside a transaction for exactly this reason; this upsert path does
      # not attempt to handle it, and this test documents that boundary
      # rather than treating it as incidental.
      show = media_item_fixture(%{type: "tv_show", title: "Collision"})

      both = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 1,
            provider_episode_id: "A"
          },
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 2,
            provider_episode_id: "B"
          }
        ]
      }

      {:ok, 2} = Media.upsert_episodes_from_season(show, both, monitor_new?: true)

      # Episode "B" tries to move onto S1E1, which "A" still occupies.
      swapped = %Mydia.Metadata.Structs.SeasonData{
        season_number: 1,
        episodes: [
          %Mydia.Metadata.Structs.EpisodeData{
            season_number: 1,
            episode_number: 1,
            provider_episode_id: "B"
          }
        ]
      }

      # The move is rejected and the count reflects it — not silent.
      assert {:ok, 0} = Media.upsert_episodes_from_season(show, swapped, monitor_new?: true)

      # Neither episode moved: "A" is untouched, and "B" stayed at its
      # original coordinates rather than landing somewhere unexpected.
      assert %{provider_episode_id: "A"} = Media.find_episode(show.id, 1, 1)
      assert %{provider_episode_id: "B"} = Media.find_episode(show.id, 1, 2)
    end
  end

  describe "episodes" do
    alias Mydia.Media.Episode

    import Mydia.MediaFixtures

    @invalid_attrs %{season_number: nil, episode_number: nil}

    test "list_episodes/1 returns all episodes for a media item" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert Media.list_episodes(media_item.id) == [episode]
    end

    test "get_episode!/1 returns the episode with given id" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert Media.get_episode!(episode.id) == episode
    end

    test "create_episode/1 with valid data creates an episode" do
      media_item = media_item_fixture(%{type: "tv_show"})

      valid_attrs = %{
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      }

      assert {:ok, %Episode{} = episode} = Media.create_episode(valid_attrs)
      assert episode.season_number == 1
      assert episode.episode_number == 1
      assert episode.title == "Pilot"
    end

    test "create_episode/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Media.create_episode(@invalid_attrs)
    end

    test "update_episode/2 with valid data updates the episode" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      update_attrs = %{title: "Updated Episode Title"}

      assert {:ok, %Episode{} = episode} = Media.update_episode(episode, update_attrs)
      assert episode.title == "Updated Episode Title"
    end

    test "delete_episode/1 deletes the episode" do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(media_item_id: media_item.id)
      assert {:ok, %Episode{}} = Media.delete_episode(episode)
      assert_raise Ecto.NoResultsError, fn -> Media.get_episode!(episode.id) end
    end

    test "create_episode/1 casts and persists absolute_number and provider_episode_id" do
      media_item = media_item_fixture(%{type: "tv_show"})

      attrs = %{
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 52,
        absolute_number: 52,
        provider_episode_id: "6832458"
      }

      assert {:ok, %Episode{} = episode} = Media.create_episode(attrs)
      assert episode.absolute_number == 52
      assert episode.provider_episode_id == "6832458"

      # Round-trip through the database, not just the in-memory struct.
      reloaded = Media.get_episode!(episode.id)
      assert reloaded.absolute_number == 52
      assert reloaded.provider_episode_id == "6832458"
    end

    test "duplicate provider_episode_id under the same media_item is rejected" do
      media_item = media_item_fixture(%{type: "tv_show"})

      assert {:ok, _first} =
               Media.create_episode(%{
                 media_item_id: media_item.id,
                 season_number: 1,
                 episode_number: 1,
                 provider_episode_id: "tvdb-6832458"
               })

      # No unique_constraint/3 maps this index yet (deferred to a later task),
      # so the DB-level violation surfaces as a raise rather than an error
      # changeset. Assert the behavior that exists today.
      assert_raise Ecto.ConstraintError, fn ->
        Media.create_episode(%{
          media_item_id: media_item.id,
          season_number: 2,
          episode_number: 1,
          provider_episode_id: "tvdb-6832458"
        })
      end
    end

    test "create_episode/1 allows multiple episodes with no provider_episode_id under the same media_item" do
      # Every existing episode is in this state until the backfill (a later
      # task) runs, so create_episode/1 must not treat an unset
      # provider_episode_id as a value that has to be unique. This does not
      # exercise the migration's `where:` clause specifically — a plain,
      # non-partial unique index already permits unlimited NULLs per
      # media_item_id, since SQL treats NULL as distinct from NULL on both
      # adapters. The `where:` clause is a size optimization for the index,
      # not a correctness requirement, so there is no behavior here that
      # pins it.
      media_item = media_item_fixture(%{type: "tv_show"})

      assert {:ok, _} =
               Media.create_episode(%{
                 media_item_id: media_item.id,
                 season_number: 1,
                 episode_number: 1
               })

      assert {:ok, _} =
               Media.create_episode(%{
                 media_item_id: media_item.id,
                 season_number: 1,
                 episode_number: 2
               })

      assert {:ok, _} =
               Media.create_episode(%{
                 media_item_id: media_item.id,
                 season_number: 1,
                 episode_number: 3
               })

      assert length(Media.list_episodes(media_item.id)) == 3
    end
  end

  describe "category classification" do
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures

    test "create_media_item/1 auto-classifies movies without animation genre" do
      attrs = %{
        type: "movie",
        title: "Regular Movie",
        year: 2024,
        metadata: %{genres: ["Drama", "Action"]}
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "movie"
      assert media_item.category_override == false
    end

    test "create_media_item/1 auto-classifies anime movies" do
      attrs = %{
        type: "movie",
        title: "Anime Movie",
        year: 2024,
        metadata: %{
          genres: ["Animation", "Adventure"],
          origin_country: ["JP"],
          original_language: "ja"
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "anime_movie"
    end

    test "create_media_item/1 auto-classifies cartoon movies" do
      attrs = %{
        type: "movie",
        title: "Cartoon Movie",
        year: 2024,
        metadata: %{
          genres: ["Animation", "Family"],
          origin_country: ["US"],
          original_language: "en"
        }
      }

      assert {:ok, %MediaItem{} = media_item} = Media.create_media_item(attrs)
      assert media_item.category == "cartoon_movie"
    end

    test "create_media_item/1 auto-classifies TV shows" do
      attrs = %{
        type: "tv_show",
        title: "Regular TV Show",
        metadata: %{genres: ["Drama"]}
      }

      assert {:ok, %MediaItem{} = media_item} =
               Media.create_media_item(attrs, skip_episode_refresh: true)

      assert media_item.category == "tv_show"
    end

    test "create_media_item/1 auto-classifies anime series" do
      attrs = %{
        type: "tv_show",
        title: "Anime Series",
        metadata: %{
          genres: ["Animation", "Action"],
          origin_country: ["JP"]
        }
      }

      assert {:ok, %MediaItem{} = media_item} =
               Media.create_media_item(attrs, skip_episode_refresh: true)

      assert media_item.category == "anime_series"
    end

    test "create_media_item/1 auto-classifies cartoon series" do
      attrs = %{
        type: "tv_show",
        title: "Cartoon Series",
        metadata: %{
          genres: ["Animation", "Comedy"],
          origin_country: ["US"]
        }
      }

      assert {:ok, %MediaItem{} = media_item} =
               Media.create_media_item(attrs, skip_episode_refresh: true)

      assert media_item.category == "cartoon_series"
    end

    test "update_category/2 updates the category" do
      media_item = media_item_fixture()

      assert {:ok, %MediaItem{} = updated} = Media.update_category(media_item, :anime_movie)
      assert updated.category == "anime_movie"
      assert updated.category_override == false
    end

    test "update_category/3 with override: true sets the override flag" do
      media_item = media_item_fixture()

      assert {:ok, %MediaItem{} = updated} =
               Media.update_category(media_item, :anime_movie, override: true)

      assert updated.category == "anime_movie"
      assert updated.category_override == true
    end

    test "clear_category_override/1 clears the override flag" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :anime_movie, override: true)

      assert media_item.category_override == true

      assert {:ok, %MediaItem{} = updated} = Media.clear_category_override(media_item)
      assert updated.category_override == false
    end

    test "reclassify_media_item/1 reclassifies based on metadata" do
      # Create a movie that gets classified as regular movie
      attrs = %{
        type: "movie",
        title: "Test Movie",
        year: 2024,
        metadata: %{genres: ["Drama"]}
      }

      {:ok, media_item} = Media.create_media_item(attrs)
      assert media_item.category == "movie"

      # Update metadata to make it anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{
            genres: ["Animation"],
            origin_country: ["JP"],
            original_language: "ja"
          }
        })

      # Reclassify
      assert {:ok, %MediaItem{} = reclassified} = Media.reclassify_media_item(media_item)
      assert reclassified.category == "anime_movie"
    end

    test "reclassify_media_item/1 respects category_override flag" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :cartoon_movie, override: true)

      # Update metadata to indicate anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Reclassify should NOT change the category
      assert {:ok, %MediaItem{} = unchanged} = Media.reclassify_media_item(media_item)
      assert unchanged.category == "cartoon_movie"
    end

    test "reclassify_media_item/2 with force: true ignores override" do
      media_item = media_item_fixture()
      {:ok, media_item} = Media.update_category(media_item, :cartoon_movie, override: true)

      # Update metadata to indicate anime
      {:ok, media_item} =
        Media.update_media_item(media_item, %{
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Reclassify with force should change the category
      assert {:ok, %MediaItem{} = forced} = Media.reclassify_media_item(media_item, force: true)
      assert forced.category == "anime_movie"
    end

    test "list_media_items/1 filters by category" do
      # Create movies with different categories
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Regular Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Anime Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Filter by category (atom)
      movies = Media.list_media_items(category: :movie)
      assert length(movies) == 1
      assert hd(movies).id == movie.id

      # Filter by category (string)
      anime_movies = Media.list_media_items(category: "anime_movie")
      assert length(anime_movies) == 1
      assert hd(anime_movies).id == anime.id
    end

    test "reclassify_all_media_items/0 reclassifies all non-override items" do
      # Create some items - they will be auto-classified
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie 1",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, _anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Test Movie 2",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Set override on one
      {:ok, overridden} = Media.update_category(movie, :cartoon_movie, override: true)
      assert overridden.category_override == true

      # Reclassify all
      assert {:ok, count} = Media.reclassify_all_media_items()
      assert count >= 1

      # Overridden item should remain unchanged
      updated_movie = Media.get_media_item!(movie.id)
      assert updated_movie.category == "cartoon_movie"
    end

    test "reclassify_media_items/2 reclassifies selected items by ID" do
      # Create items with specific metadata
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Regular Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      {:ok, anime} =
        Media.create_media_item(%{
          type: "movie",
          title: "Anime Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Verify initial classifications
      assert movie.category == "movie"
      assert anime.category == "anime_movie"

      # Manually change anime to a wrong category (for testing re-classification)
      {:ok, _} = Media.update_category(anime, :movie)

      # Re-classify specific items
      {:ok, summary} = Media.reclassify_media_items([anime.id])

      assert summary.total == 1
      assert summary.updated == 1
      assert summary.skipped == 0
      assert summary.unchanged == 0

      # Verify it was reclassified correctly
      updated_anime = Media.get_media_item!(anime.id)
      assert updated_anime.category == "anime_movie"
    end

    test "reclassify_media_items/2 respects category_override flag" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Overridden Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Should be classified as anime_movie
      assert movie.category == "anime_movie"

      # Set override to a different category
      {:ok, overridden} = Media.update_category(movie, :movie, override: true)
      assert overridden.category_override == true
      assert overridden.category == "movie"

      # Try to reclassify - should be skipped
      {:ok, summary} = Media.reclassify_media_items([movie.id])

      assert summary.total == 1
      assert summary.updated == 0
      assert summary.skipped == 1

      # Verify category unchanged
      still_overridden = Media.get_media_item!(movie.id)
      assert still_overridden.category == "movie"
    end

    test "reclassify_media_items/2 with force: true ignores override" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Force Reclassify Movie",
          year: 2024,
          metadata: %{genres: ["Animation"], origin_country: ["JP"]}
        })

      # Set override to wrong category
      {:ok, overridden} = Media.update_category(movie, :movie, override: true)
      assert overridden.category == "movie"
      assert overridden.category_override == true

      # Force reclassify
      {:ok, summary} = Media.reclassify_media_items([movie.id], force: true)

      assert summary.updated == 1
      assert summary.skipped == 0

      # Verify it was reclassified
      updated = Media.get_media_item!(movie.id)
      assert updated.category == "anime_movie"
    end

    test "reclassify_media_items/2 returns correct summary with unchanged items" do
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Already Correct Movie",
          year: 2024,
          metadata: %{genres: ["Drama"]}
        })

      # Verify it's already correctly classified
      assert movie.category == "movie"

      # Reclassify - should not change anything
      {:ok, summary} = Media.reclassify_media_items([movie.id])

      assert summary.total == 1
      assert summary.updated == 0
      assert summary.skipped == 0
      assert summary.unchanged == 1
    end
  end

  describe "monitoring presets" do
    alias Mydia.Media.{MediaItem, Episode}
    import Mydia.MediaFixtures

    test "monitoring_presets/0 returns all valid presets" do
      presets = Media.monitoring_presets()
      assert :all in presets
      assert :missing in presets
      # :existing is what leaves the Upgrades sweep something to act on.
      assert :existing in presets
      assert :future in presets
      assert :none in presets
      assert length(presets) == 5
    end

    # Movie invalid-type covered by media_items "apply_episode_monitoring/2 returns an error for movies"

    test "apply_episode_monitoring/2 with :all monitors all episodes except specials" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      # Create episodes in different seasons including specials
      episode_fixture(
        media_item_id: media_item.id,
        season_number: 0,
        episode_number: 1,
        monitored: false
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        monitored: false
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 2,
        monitored: false
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 2,
        episode_number: 1,
        monitored: false
      )

      {:ok, count} = Media.apply_episode_monitoring(media_item, :all)

      assert count == 4

      # Verify episode states
      episodes = Media.list_episodes(media_item.id)
      special = Enum.find(episodes, &(&1.season_number == 0))
      s1e1 = Enum.find(episodes, &(&1.season_number == 1 && &1.episode_number == 1))
      s1e2 = Enum.find(episodes, &(&1.season_number == 1 && &1.episode_number == 2))
      s2e1 = Enum.find(episodes, &(&1.season_number == 2 && &1.episode_number == 1))

      refute special.monitored
      assert s1e1.monitored
      assert s1e2.monitored
      assert s2e1.monitored
    end

    test "apply_episode_monitoring/2 with :none unmonitors all episodes" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      # Create monitored episodes
      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        monitored: true
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 2,
        monitored: true
      )

      {:ok, count} = Media.apply_episode_monitoring(media_item, :none)

      assert count == 2

      # Verify all episodes are unmonitored
      episodes = Media.list_episodes(media_item.id)
      assert Enum.all?(episodes, &(!&1.monitored))
    end

    test "apply_episode_monitoring/2 with :future monitors only future episodes" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      today = Date.utc_today()
      past_date = Date.add(today, -30)
      future_date = Date.add(today, 30)

      # Create past and future episodes
      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 1,
        air_date: past_date,
        monitored: true
      )

      episode_fixture(
        media_item_id: media_item.id,
        season_number: 1,
        episode_number: 2,
        air_date: future_date,
        monitored: false
      )

      {:ok, _count} = Media.apply_episode_monitoring(media_item, :future)

      # Verify episode states
      episodes = Media.list_episodes(media_item.id)
      past_ep = Enum.find(episodes, &(&1.air_date == past_date))
      future_ep = Enum.find(episodes, &(&1.air_date == future_date))

      refute past_ep.monitored
      assert future_ep.monitored
    end

    test "apply_episode_monitoring/2 with :missing monitors episodes without files or future" do
      media_item = media_item_fixture(%{type: "tv_show", monitored: true})

      today = Date.utc_today()
      future_date = Date.add(today, 30)

      # Create episodes
      ep_with_file =
        episode_fixture(
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 1,
          monitored: true
        )

      _ep_missing =
        episode_fixture(
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 2,
          monitored: false
        )

      _ep_future =
        episode_fixture(
          media_item_id: media_item.id,
          season_number: 1,
          episode_number: 3,
          air_date: future_date,
          monitored: false
        )

      # Add a media file to the first episode
      media_file_fixture(episode_id: ep_with_file.id)

      {:ok, _count} = Media.apply_episode_monitoring(media_item, :missing)

      # Verify episode states
      episodes = Media.list_episodes(media_item.id, preload: [:media_files])

      ep_with = Enum.find(episodes, &(&1.episode_number == 1))
      ep_missing = Enum.find(episodes, &(&1.episode_number == 2))
      ep_future = Enum.find(episodes, &(&1.episode_number == 3))

      # Has file
      refute ep_with.monitored
      # Missing file
      assert ep_missing.monitored
      # Future
      assert ep_future.monitored
    end

    # "persists the preset" removed: apply is now stateless; covered by
    # media_items "apply_episode_monitoring/2 does not persist anything on the show"

    test "apply_episode_monitoring/2 handles empty episode list" do
      media_item = media_item_fixture(%{type: "tv_show"})

      # No episodes created

      {:ok, count} = Media.apply_episode_monitoring(media_item, :all)

      assert count == 0
    end
  end

  describe "list_movies_by_release_date/3" do
    alias Mydia.Media.Structs.CalendarEntry

    import Mydia.MediaFixtures

    test "returns movies with release dates in range" do
      media_item_fixture(%{
        type: "movie",
        title: "In Range Movie",
        year: 2025,
        metadata: %{
          provider_id: "1",
          provider: :metadata_relay,
          media_type: :movie,
          release_date: ~D[2025-06-15]
        }
      })

      entries = Media.list_movies_by_release_date(~D[2025-06-01], ~D[2025-06-30])

      assert [%CalendarEntry{} = entry] = entries
      assert entry.title == "In Range Movie"
      assert entry.air_date == ~D[2025-06-15]
      assert entry.type == "movie"
    end

    test "excludes movies with release dates outside range" do
      media_item_fixture(%{
        type: "movie",
        title: "Before Range",
        year: 2025,
        metadata: %{
          provider_id: "2",
          provider: :metadata_relay,
          media_type: :movie,
          release_date: ~D[2025-05-31]
        }
      })

      media_item_fixture(%{
        type: "movie",
        title: "After Range",
        year: 2025,
        metadata: %{
          provider_id: "3",
          provider: :metadata_relay,
          media_type: :movie,
          release_date: ~D[2025-07-01]
        }
      })

      entries = Media.list_movies_by_release_date(~D[2025-06-01], ~D[2025-06-30])
      assert entries == []
    end

    test "excludes movies without release dates" do
      media_item_fixture(%{
        type: "movie",
        title: "No Release Date",
        year: 2025,
        metadata: %{genres: ["Drama"]}
      })

      entries = Media.list_movies_by_release_date(~D[2025-01-01], ~D[2025-12-31])
      assert entries == []
    end

    test "includes boundary dates" do
      media_item_fixture(%{
        type: "movie",
        title: "Start Boundary",
        year: 2025,
        metadata: %{
          provider_id: "4",
          provider: :metadata_relay,
          media_type: :movie,
          release_date: ~D[2025-06-01]
        }
      })

      media_item_fixture(%{
        type: "movie",
        title: "End Boundary",
        year: 2025,
        metadata: %{
          provider_id: "5",
          provider: :metadata_relay,
          media_type: :movie,
          release_date: ~D[2025-06-30]
        }
      })

      entries = Media.list_movies_by_release_date(~D[2025-06-01], ~D[2025-06-30])
      assert length(entries) == 2
      titles = Enum.map(entries, & &1.title)
      assert "Start Boundary" in titles
      assert "End Boundary" in titles
    end

    test "sets has_files and has_downloads correctly" do
      movie =
        media_item_fixture(%{
          type: "movie",
          title: "Movie With File",
          year: 2025,
          metadata: %{
            provider_id: "6",
            provider: :metadata_relay,
            media_type: :movie,
            release_date: ~D[2025-06-15]
          }
        })

      media_file_fixture(media_item_id: movie.id)

      entries = Media.list_movies_by_release_date(~D[2025-06-01], ~D[2025-06-30])

      assert [%CalendarEntry{} = entry] = entries
      assert entry.has_files == true
      assert entry.has_downloads == false
    end
  end

  describe "list_movies_by_release_date/3 filtering" do
    import Mydia.MediaFixtures

    setup do
      inside = media_item_fixture(%{type: "movie", title: "Inside"})
      edge_low = media_item_fixture(%{type: "movie", title: "EdgeLow"})
      edge_high = media_item_fixture(%{type: "movie", title: "EdgeHigh"})
      outside = media_item_fixture(%{type: "movie", title: "Outside"})
      undated = media_item_fixture(%{type: "movie", title: "Undated"})

      set_release_date(inside, ~D[2026-08-15])
      set_release_date(edge_low, ~D[2026-08-01])
      set_release_date(edge_high, ~D[2026-08-31])
      set_release_date(outside, ~D[2026-09-05])

      %{inside: inside, edge_low: edge_low, edge_high: edge_high, undated: undated}
    end

    test "returns only movies inside the range, with both bounds included", ctx do
      titles =
        Mydia.Media.list_movies_by_release_date(~D[2026-08-01], ~D[2026-08-31], monitored: nil)
        |> Enum.map(& &1.media_item_title)
        |> Enum.sort()

      assert titles == ["EdgeHigh", "EdgeLow", "Inside"]
      refute ctx.undated.title in titles
    end

    test "reports has_files from the database", ctx do
      Mydia.MediaFixtures.media_file_fixture(%{media_item_id: ctx.inside.id})

      entries =
        Mydia.Media.list_movies_by_release_date(~D[2026-08-01], ~D[2026-08-31], monitored: nil)

      with_files = Enum.find(entries, &(&1.media_item_title == "Inside"))
      without_files = Enum.find(entries, &(&1.media_item_title == "EdgeLow"))

      assert with_files.has_files
      refute without_files.has_files
    end

    test "monitored: nil includes unmonitored movies" do
      unmonitored = media_item_fixture(%{type: "movie", title: "Unmonitored", monitored: false})
      set_release_date(unmonitored, ~D[2026-08-10])

      titles =
        Mydia.Media.list_movies_by_release_date(~D[2026-08-01], ~D[2026-08-31], monitored: nil)
        |> Enum.map(& &1.media_item_title)

      assert "Unmonitored" in titles
    end

    # Identical to the helper Task 1 added to test/mydia/db_test.exs. The struct
    # is Mydia.Metadata.Structs.MediaMetadata, and it carries @enforce_keys on
    # :provider_id, :provider and :media_type, so a fresh one cannot be built
    # empty. Copy this verbatim rather than reconstructing it.
    defp set_release_date(item, date) do
      metadata =
        case item.metadata do
          nil ->
            %Mydia.Metadata.Structs.MediaMetadata{
              provider_id: to_string(item.id),
              provider: :metadata_relay,
              media_type: :movie,
              release_date: date
            }

          existing ->
            %{existing | release_date: date}
        end

      item
      |> Ecto.Changeset.change(metadata: metadata)
      |> Mydia.Repo.update!()
    end
  end

  describe "resolve_library_provider/1 (U6)" do
    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    test "returns the provider of a directly-linked file's series library" do
      item = media_item_fixture(%{type: "tv_show", title: "Show A"})
      lib = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})
      media_file_fixture(%{media_item_id: item.id, library_path_id: lib.id})

      assert Mydia.Media.ProviderSwitch.resolve_library_provider(item) == {:ok, :tvdb}
    end

    test "finds the library for an episode-linked file (media_item_id nil)" do
      item = media_item_fixture(%{type: "tv_show", title: "Show B"})
      lib = library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})
      episode = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
      media_file_fixture(%{episode_id: episode.id, library_path_id: lib.id})

      assert Mydia.Media.ProviderSwitch.resolve_library_provider(item) == {:ok, :tmdb}
    end

    test "is :ambiguous when files span libraries with different providers" do
      item = media_item_fixture(%{type: "tv_show", title: "Show C"})
      tvdb_lib = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})
      tmdb_lib = library_path_fixture(%{type: "mixed", tv_metadata_source: :tmdb})
      media_file_fixture(%{media_item_id: item.id, library_path_id: tvdb_lib.id})
      episode = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
      media_file_fixture(%{episode_id: episode.id, library_path_id: tmdb_lib.id})

      assert Mydia.Media.ProviderSwitch.resolve_library_provider(item) == :ambiguous
    end

    test "is :none when the show is in no series/mixed library" do
      item = media_item_fixture(%{type: "tv_show", title: "Show D"})
      assert Mydia.Media.ProviderSwitch.resolve_library_provider(item) == :none
    end
  end

  describe "provider_refresh_decision/1 (U6)" do
    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    test "re-fetches when stored source matches the library provider" do
      item = decision_tv_in_library(:tvdb, :tvdb)
      assert Mydia.Media.ProviderSwitch.provider_refresh_decision(item) == :refetch
    end

    test "re-identifies when the library provider differs from stored source" do
      item = decision_tv_in_library(:tvdb, :tmdb)
      assert Mydia.Media.ProviderSwitch.provider_refresh_decision(item) == {:reidentify, :tmdb}
    end

    test "re-fetches (no re-identify) when libraries are ambiguous" do
      item = media_item_fixture(%{type: "tv_show", title: "Amb", metadata_source: :tvdb})
      a = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})
      b = library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})
      media_file_fixture(%{media_item_id: item.id, library_path_id: a.id})
      ep = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
      media_file_fixture(%{episode_id: ep.id, library_path_id: b.id})

      assert Mydia.Media.ProviderSwitch.provider_refresh_decision(item) == :refetch
    end

    test "re-fetches when metadata_source is nil (pre-feature item)" do
      item = decision_tv_in_library(nil, :tmdb)
      assert Mydia.Media.ProviderSwitch.provider_refresh_decision(item) == :refetch
    end

    test "movies always re-fetch" do
      item = media_item_fixture(%{type: "movie", title: "A Movie", year: 2020})
      assert Mydia.Media.ProviderSwitch.provider_refresh_decision(item) == :refetch
    end

    defp decision_tv_in_library(metadata_source, lib_provider) do
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Decision Show #{System.unique_integer([:positive])}",
          metadata_source: metadata_source
        })

      lib = library_path_fixture(%{type: "series", tv_metadata_source: lib_provider})
      media_file_fixture(%{media_item_id: item.id, library_path_id: lib.id})
      item
    end
  end

  describe "find_reidentify_candidate/3 (U6)" do
    import Mydia.MediaFixtures

    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "returns :confident for a near-exact title, matching year, and matching imdb_id",
         %{bypass: bypass, config: config} do
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Ghost in the Shell",
          year: 2002,
          imdb_id: "tt0303115"
        })

      Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(tmdb_tv_search(9001, "Ghost in the Shell", 2002, "tt0303115"))
        )
      end)

      assert {:confident, candidate} =
               Mydia.Media.ProviderSwitch.find_reidentify_candidate(item, :tmdb, config)

      assert candidate.provider_id == "9001"
    end

    test "returns :needs_picker when no candidate matches confidently",
         %{bypass: bypass, config: config} do
      item = media_item_fixture(%{type: "tv_show", title: "Ghost in the Shell", year: 2002})

      Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(tmdb_tv_search(9002, "Totally Different Show", 1990))
        )
      end)

      assert {:needs_picker, candidates} =
               Mydia.Media.ProviderSwitch.find_reidentify_candidate(item, :tmdb, config)

      assert length(candidates) == 1
    end

    test "returns :needs_picker when title+year match but imdb_id is missing on the candidate",
         %{bypass: bypass, config: config} do
      # Finding #3: title + year alone is no longer confident; without an
      # imdb_id to corroborate, the operator must confirm via the picker.
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Ghost in the Shell",
          year: 2002,
          imdb_id: "tt0303115"
        })

      Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        # No imdb_id on the candidate.
        |> Plug.Conn.resp(200, Jason.encode!(tmdb_tv_search(9001, "Ghost in the Shell", 2002)))
      end)

      assert {:needs_picker, [_ | _]} =
               Mydia.Media.ProviderSwitch.find_reidentify_candidate(item, :tmdb, config)
    end

    test "returns :needs_picker when title+year match but imdb_ids differ (remake guard)",
         %{bypass: bypass, config: config} do
      # Finding #3: a remake/reboot sharing title + year but with a different
      # imdb_id must NOT silently auto-adopt and wipe episodes.
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Ghost in the Shell",
          year: 2002,
          imdb_id: "tt0303115"
        })

      Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(tmdb_tv_search(9001, "Ghost in the Shell", 2002, "tt9999999"))
        )
      end)

      assert {:needs_picker, [_ | _]} =
               Mydia.Media.ProviderSwitch.find_reidentify_candidate(item, :tmdb, config)
    end

    defp tmdb_tv_search(id, name, year, imdb_id \\ nil) do
      result =
        %{"id" => id, "name" => name, "first_air_date" => "#{year}-01-01", "overview" => "x"}
        |> then(fn r -> if imdb_id, do: Map.put(r, "imdb_id", imdb_id), else: r end)

      %{"results" => [result]}
    end
  end

  describe "adopt_provider_switch/4 (U7)" do
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Switch Show",
          year: 2010,
          tvdb_id: 555,
          metadata_source: :tvdb
        })

      lib = library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      old_episode =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      media_file =
        media_file_fixture(%{
          episode_id: old_episode.id,
          library_path_id: lib.id,
          relative_path: "Switch Show/Season 01/Switch.Show.S01E01.1080p.mkv"
        })

      # Unique id per test: the metadata cache is keyed by provider_id and
      # persists across tests, so a fixed id would leak cached season data.
      new_id = System.unique_integer([:positive])

      candidate = %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(new_id),
        provider: :metadata_relay,
        media_type: :tv_show,
        title: "Switch Show",
        year: 2010
      }

      %{
        bypass: bypass,
        config: config,
        item: item,
        old_episode: old_episode,
        media_file: media_file,
        candidate: candidate,
        new_id: new_id
      }
    end

    # A provider switch re-identifies the show, so whichever of TVDB's parallel
    # orderings the user had picked describes a series record this no longer
    # is. The show goes back to "never asked", which is also what lets the
    # suggestion banner re-offer the new provider's alternative.
    test "clears the season ordering the old provider's record was in", ctx do
      stub_tmdb_show(ctx.bypass, ctx.new_id, "Switch Show", 2010)
      stub_tmdb_season(ctx.bypass, ctx.new_id, 1, [1, 2])

      Mydia.Repo.update_all(
        from(m in MediaItem, where: m.id == ^ctx.item.id),
        set: [season_order: :dvd]
      )

      picked = Mydia.Repo.get!(MediaItem, ctx.item.id)
      assert picked.season_order == :dvd

      assert {:ok, reconciled} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 picked,
                 ctx.candidate,
                 :tmdb,
                 ctx.config
               )

      assert is_nil(reconciled.season_order)
      assert is_nil(Mydia.Repo.get!(MediaItem, reconciled.id).season_order)
    end

    test "swaps provider ids, recreates episodes, and re-links files", ctx do
      stub_tmdb_show(ctx.bypass, ctx.new_id, "Switch Show", 2010)
      stub_tmdb_season(ctx.bypass, ctx.new_id, 1, [1, 2])

      assert {:ok, reconciled} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 ctx.item,
                 ctx.candidate,
                 :tmdb,
                 ctx.config
               )

      # Provider ids swapped; provenance updated.
      assert reconciled.tmdb_id == ctx.new_id
      assert is_nil(reconciled.tvdb_id)
      assert reconciled.metadata_source == :tmdb

      # Episodes recreated under the new provider's numbering.
      episodes = Media.list_episodes(reconciled.id)
      numbers = episodes |> Enum.map(& &1.episode_number) |> Enum.sort()
      assert numbers == [1, 2]

      # The old episode row is gone (wiped, not left parallel).
      assert is_nil(Mydia.Repo.get(Mydia.Media.Episode, ctx.old_episode.id))

      # The previously episode-linked file is still attached to the show
      # (re-linked by filename), not orphaned with both ids null.
      media_file = Mydia.Repo.get(Mydia.Library.MediaFile, ctx.media_file.id)
      refute is_nil(media_file)
      # Re-linked by filename to a recreated episode (not left orphaned).
      assert not is_nil(media_file.episode_id)

      relinked = Mydia.Repo.get(Mydia.Media.Episode, media_file.episode_id)
      assert relinked.season_number == 1
      assert relinked.episode_number == 1
    end

    test "a failed new-provider fetch leaves existing episodes intact", ctx do
      Bypass.expect(ctx.bypass, "GET", "/tmdb/tv/shows/#{ctx.new_id}", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      assert {:error, _reason} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 ctx.item,
                 ctx.candidate,
                 :tmdb,
                 ctx.config
               )

      # No mutation: old episode and provider ids untouched.
      assert Mydia.Repo.get(Mydia.Media.Episode, ctx.old_episode.id)
      item = Media.get_media_item!(ctx.item.id)
      assert item.tvdb_id == 555
      assert is_nil(item.tmdb_id)
      assert item.metadata_source == :tvdb
    end

    test "an empty season set aborts without wiping episodes", ctx do
      stub_tmdb_show(ctx.bypass, ctx.new_id, "Switch Show", 2010)
      stub_tmdb_season(ctx.bypass, ctx.new_id, 1, [])

      assert {:error, :no_episodes} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 ctx.item,
                 ctx.candidate,
                 :tmdb,
                 ctx.config
               )

      assert Mydia.Repo.get(Mydia.Media.Episode, ctx.old_episode.id)
    end

    test "clears a stale season_order picked under the old provider", ctx do
      # The item is switching providers entirely, so whatever ordering the
      # user picked under the old provider's TVDB ids describes nothing on
      # the new provider — it must not survive the switch.
      {:ok, item} = Media.update_media_item(ctx.item, %{season_order: :dvd})
      assert item.season_order == :dvd

      stub_tmdb_show(ctx.bypass, ctx.new_id, "Switch Show", 2010)
      stub_tmdb_season(ctx.bypass, ctx.new_id, 1, [1, 2])

      assert {:ok, reconciled} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 item,
                 ctx.candidate,
                 :tmdb,
                 ctx.config
               )

      assert is_nil(reconciled.season_order)
    end

    defp stub_tmdb_show(bypass, id, name, year) do
      body = %{
        "id" => id,
        "name" => name,
        "first_air_date" => "#{year}-01-01",
        "overview" => "x",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "seasons" => [%{"season_number" => 1, "name" => "Season 1"}]
      }

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)
    end

    defp stub_tmdb_season(bypass, id, season_number, episode_numbers) do
      episodes =
        Enum.map(episode_numbers, fn n ->
          %{
            "season_number" => season_number,
            "episode_number" => n,
            "name" => "Episode #{n}",
            "air_date" => "2010-01-0#{n}"
          }
        end)

      body = %{"season_number" => season_number, "episodes" => episodes}

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{id}/#{season_number}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)
    end
  end

  describe "adopt_provider_switch/4 TVDB target (U7)" do
    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      # Switching FROM tmdb TO tvdb: item starts as a TMDB-sourced show.
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "TVDB Show",
          year: 2010,
          tmdb_id: 777,
          metadata_source: :tmdb
        })

      lib = library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})

      old_episode =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      media_file =
        media_file_fixture(%{
          episode_id: old_episode.id,
          library_path_id: lib.id,
          relative_path: "TVDB Show/Season 01/TVDB.Show.S01E01.1080p.mkv"
        })

      new_id = System.unique_integer([:positive])

      candidate = %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(new_id),
        provider: :tvdb,
        media_type: :tv_show,
        title: "TVDB Show",
        year: 2010
      }

      %{
        bypass: bypass,
        config: config,
        item: item,
        old_episode: old_episode,
        media_file: media_file,
        candidate: candidate,
        new_id: new_id
      }
    end

    test "swaps to tvdb ids, recreates episodes, and re-links files", ctx do
      tvdb_season_id = System.unique_integer([:positive])
      stub_tvdb_show(ctx.bypass, ctx.new_id, "TVDB Show", 2010, [{1, tvdb_season_id}])
      stub_tvdb_season(ctx.bypass, tvdb_season_id, 1, [1, 2])

      assert {:ok, reconciled} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 ctx.item,
                 ctx.candidate,
                 :tvdb,
                 ctx.config
               )

      # Provider ids swapped; provenance updated to TVDB.
      assert reconciled.tvdb_id == ctx.new_id
      assert is_nil(reconciled.tmdb_id)
      assert reconciled.metadata_source == :tvdb

      # Episodes recreated under the new provider's numbering.
      episodes = Media.list_episodes(reconciled.id)
      numbers = episodes |> Enum.map(& &1.episode_number) |> Enum.sort()
      assert numbers == [1, 2]

      # The old episode row is gone (wiped, not left parallel).
      assert is_nil(Mydia.Repo.get(Mydia.Media.Episode, ctx.old_episode.id))

      # The previously episode-linked file is re-linked by filename.
      media_file = Mydia.Repo.get(Mydia.Library.MediaFile, ctx.media_file.id)
      refute is_nil(media_file)
      assert not is_nil(media_file.episode_id)
    end

    test "clears a stale season_order picked under the old provider", ctx do
      {:ok, item} = Media.update_media_item(ctx.item, %{season_order: :dvd})
      assert item.season_order == :dvd

      tvdb_season_id = System.unique_integer([:positive])
      stub_tvdb_show(ctx.bypass, ctx.new_id, "TVDB Show", 2010, [{1, tvdb_season_id}])
      stub_tvdb_season(ctx.bypass, tvdb_season_id, 1, [1, 2])

      assert {:ok, reconciled} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 item,
                 ctx.candidate,
                 :tvdb,
                 ctx.config
               )

      assert is_nil(reconciled.season_order)
    end

    test "a season missing tvdb_season_id aborts without wiping episodes", ctx do
      # Season carries no tvdb_season_id -> hard failure before any mutation.
      stub_tvdb_show(ctx.bypass, ctx.new_id, "TVDB Show", 2010, [{1, nil}])

      assert {:error, {:missing_tvdb_season_id, 1}} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(
                 ctx.item,
                 ctx.candidate,
                 :tvdb,
                 ctx.config
               )

      # Nothing wiped: original episode and provider id intact.
      assert Mydia.Repo.get(Mydia.Media.Episode, ctx.old_episode.id)
      reloaded = Media.get_media_item!(ctx.item.id)
      assert reloaded.tmdb_id == 777
      assert is_nil(reloaded.tvdb_id)
      assert reloaded.metadata_source == :tmdb
    end

    # TVDB show extended endpoint. `seasons` is a list of {season_number,
    # tvdb_season_id} tuples; a nil tvdb_season_id omits the id so the switch
    # treats that season as un-fetchable.
    defp stub_tvdb_show(bypass, id, name, year, seasons) do
      season_maps =
        Enum.map(seasons, fn {season_number, tvdb_season_id} ->
          %{
            "id" => tvdb_season_id,
            "number" => season_number,
            "name" => "Season #{season_number}",
            "type" => %{"type" => "official"},
            "episodeCount" => 2
          }
        end)

      body = %{
        "data" => %{
          "id" => id,
          "name" => name,
          "firstAired" => "#{year}-01-01",
          "year" => to_string(year),
          "status" => %{"name" => "Ended"},
          "seasons" => season_maps,
          "genres" => [],
          "episodes" => []
        }
      }

      Bypass.expect(bypass, "GET", "/tvdb/series/#{id}/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)
    end

    # TVDB season extended endpoint. Episodes omit "id" so the per-episode
    # translation enrichment fetch is skipped.
    defp stub_tvdb_season(bypass, tvdb_season_id, season_number, episode_numbers) do
      episodes =
        Enum.map(episode_numbers, fn n ->
          %{
            "seasonNumber" => season_number,
            "number" => n,
            "name" => "Episode #{n}",
            "aired" => "2010-01-0#{n}"
          }
        end)

      body = %{"data" => %{"number" => season_number, "episodes" => episodes}}

      Bypass.expect(bypass, "GET", "/tvdb/seasons/#{tvdb_season_id}/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)
    end
  end

  describe "provider switch edge cases (review fixes)" do
    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "a partial season-fetch failure aborts the switch without wiping episodes",
         %{bypass: bypass, config: config} do
      new_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Partial Show",
          year: 2010,
          tvdb_id: 444,
          metadata_source: :tvdb
        })

      old_episode =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      # Show reports TWO seasons.
      show_body = %{
        "id" => new_id,
        "name" => "Partial Show",
        "first_air_date" => "2010-01-01",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "seasons" => [
          %{"season_number" => 1, "name" => "S1"},
          %{"season_number" => 2, "name" => "S2"}
        ]
      }

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(show_body))
      end)

      # Season 1 succeeds; season 2 errors (relay 500).
      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "season_number" => 1,
            "episodes" => [%{"season_number" => 1, "episode_number" => 1, "name" => "E1"}]
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}/2", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      candidate = %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(new_id),
        provider: :metadata_relay,
        media_type: :tv_show,
        title: "Partial Show",
        year: 2010
      }

      assert {:error, _reason} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(item, candidate, :tmdb, config)

      # Nothing wiped: original episode and provider id intact.
      assert Mydia.Repo.get(Mydia.Media.Episode, old_episode.id)
      reloaded = Media.get_media_item!(item.id)
      assert reloaded.tvdb_id == 444
      assert is_nil(reloaded.tmdb_id)
    end

    test "a provider-id collision returns an error and preserves episodes",
         %{bypass: bypass, config: config} do
      new_id = System.unique_integer([:positive])

      # Another show already owns the target tmdb_id -> unique_constraint.
      media_item_fixture(%{type: "tv_show", title: "Incumbent", tmdb_id: new_id})

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Collider",
          year: 2010,
          tvdb_id: 333,
          metadata_source: :tvdb
        })

      old_episode =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      show_body = %{
        "id" => new_id,
        "name" => "Collider",
        "first_air_date" => "2010-01-01",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "seasons" => [%{"season_number" => 1, "name" => "S1"}]
      }

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(show_body))
      end)

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "season_number" => 1,
            "episodes" => [%{"season_number" => 1, "episode_number" => 1, "name" => "E1"}]
          })
        )
      end)

      candidate = %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(new_id),
        provider: :metadata_relay,
        media_type: :tv_show,
        title: "Collider",
        year: 2010
      }

      # Returns an error instead of raising/crashing.
      assert {:error, _reason} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(item, candidate, :tmdb, config)

      # Transaction rolled back: original episode and provider id intact.
      assert Mydia.Repo.get(Mydia.Media.Episode, old_episode.id)
      reloaded = Media.get_media_item!(item.id)
      assert reloaded.tvdb_id == 333
    end

    test "incomplete episode recreation rolls back, preserving the original episodes",
         %{bypass: bypass, config: config} do
      # Finding #1: upsert_episodes_from_season/3 swallows per-episode insert
      # errors, so a payload that recreates FEWER episodes than fetched would
      # silently commit with data loss. Here the season reports TWO episodes
      # (expected count 2) but both share episode_number 1, so only one row
      # persists -> the switch must roll back instead of committing a degraded
      # show.
      new_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Dropper",
          year: 2010,
          tvdb_id: 222,
          metadata_source: :tvdb
        })

      old_episode_a =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      old_episode_b =
        episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 2})

      show_body = %{
        "id" => new_id,
        "name" => "Dropper",
        "first_air_date" => "2010-01-01",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => [],
        "seasons" => [%{"season_number" => 1, "name" => "S1"}]
      }

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(show_body))
      end)

      # Two episodes fetched (expected count 2), but both collide on
      # (season 1, episode 1) -> the second insert is swallowed and only one
      # row persists.
      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/#{new_id}/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "season_number" => 1,
            "episodes" => [
              %{"season_number" => 1, "episode_number" => 1, "name" => "E1"},
              %{"season_number" => 1, "episode_number" => 1, "name" => "E1 dup"}
            ]
          })
        )
      end)

      candidate = %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(new_id),
        provider: :metadata_relay,
        media_type: :tv_show,
        title: "Dropper",
        year: 2010
      }

      assert {:error, {:incomplete_episode_recreation, 2, 1}} =
               Mydia.Media.ProviderSwitch.adopt_provider_switch(item, candidate, :tmdb, config)

      # Rolled back: original episodes and provider id preserved.
      assert Mydia.Repo.get(Mydia.Media.Episode, old_episode_a.id)
      assert Mydia.Repo.get(Mydia.Media.Episode, old_episode_b.id)
      reloaded = Media.get_media_item!(item.id)
      assert reloaded.tvdb_id == 222
      assert is_nil(reloaded.tmdb_id)
      assert reloaded.metadata_source == :tvdb
    end

    test "a yearless show never auto-adopts (routes to the picker)",
         %{bypass: bypass, config: config} do
      # No year on the stored item -> title-only match must NOT be confident.
      item = media_item_fixture(%{type: "tv_show", title: "Yearless Show"})

      Bypass.expect(bypass, "GET", "/tmdb/tv/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{"id" => 5150, "name" => "Yearless Show", "first_air_date" => "1999-01-01"}
            ]
          })
        )
      end)

      assert {:needs_picker, [_ | _]} =
               Mydia.Media.ProviderSwitch.find_reidentify_candidate(item, :tmdb, config)
    end
  end

  describe "refresh_metadata/2 provider routing (U6)" do
    import Mydia.MediaFixtures

    setup do
      bypass = Bypass.open()

      # Inject the relay config directly so this test never mutates the global
      # METADATA_RELAY_URL env var (which would race concurrent async tests).
      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "a TMDB-sourced show with a back-filled tvdb_id refreshes from TMDB", %{
      bypass: bypass,
      config: config
    } do
      # metadata_source is :tmdb but a discovered tvdb_id is also present; the
      # legacy rule would prefer TVDB. Only the TMDB endpoint is stubbed, so a
      # wrong-provider fetch hits an unstubbed TVDB path and fails (404).
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "TMDB Sourced",
          metadata_source: :tmdb,
          tmdb_id: 12_345,
          tvdb_id: 67_890
        })

      # `expect` plus an explicit count, not `expect_once`: the episode leg of
      # the refresh re-fetches the show to read its season list, so the endpoint
      # is hit twice. It used to be hit once here only because that leg dropped
      # the injected config and escaped to the global default relay — the
      # routing this test exists to pin was never actually covered for the
      # episode fetch. Counting rather than dropping the assertion keeps a third
      # fetch from slipping in unnoticed. A wrong-provider fetch still fails,
      # since no TVDB path is stubbed.
      show_fetches = :atomics.new(1, signed: false)

      Bypass.expect(bypass, "GET", "/tmdb/tv/shows/12345", fn conn ->
        :atomics.add(show_fetches, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => 12_345,
            "name" => "TMDB Sourced",
            "first_air_date" => "2010-01-01",
            "overview" => "x",
            "credits" => %{"cast" => [], "crew" => []},
            "genres" => [],
            "seasons" => []
          })
        )
      end)

      assert {:ok, _updated} = Mydia.Media.refresh_metadata(item, config)

      # Both legs fetched the show, and both went to TMDB: the item-level
      # refresh and the episode refresh that reads the season list.
      assert :atomics.get(show_fetches, 1) == 2
    end
  end

  describe "file deletion return shape" do
    alias Mydia.Library
    alias Mydia.Media.MediaItem

    import Mydia.MediaFixtures
    import Mydia.SettingsFixtures

    setup do
      tmp = Path.join(System.tmp_dir!(), "mydia_media_del_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      %{library_path: library_path_fixture(%{path: tmp, type: "movies"})}
    end

    defp movie_with_file(lp, rel, contents) do
      media_item = media_item_fixture(%{type: "movie"})
      File.write!(Path.join(lp.path, rel), contents)

      {:ok, _file} =
        Library.create_scanned_media_file(%{
          relative_path: rel,
          library_path_id: lp.id,
          media_item_id: media_item.id,
          size: byte_size(contents)
        })

      media_item
    end

    test "delete_media_item/2 with delete_files: true reports zero errors on success", %{
      library_path: lp
    } do
      item = movie_with_file(lp, "movie.mkv", "data")
      abs = Path.join(lp.path, "movie.mkv")

      assert {:ok, %MediaItem{}, 0} = Media.delete_media_item(item, delete_files: true)
      refute File.exists?(abs)
    end

    test "delete_media_item/2 reports the error count when a file cannot be removed", %{
      library_path: lp
    } do
      # A directory at the file path makes the on-disk removal fail.
      media_item = media_item_fixture(%{type: "movie"})
      File.mkdir_p!(Path.join(lp.path, "as_dir.mkv"))

      {:ok, _file} =
        Library.create_scanned_media_file(%{
          relative_path: "as_dir.mkv",
          library_path_id: lp.id,
          media_item_id: media_item.id,
          size: 1
        })

      assert {:ok, %MediaItem{}, 1} = Media.delete_media_item(media_item, delete_files: true)
      assert_raise Ecto.NoResultsError, fn -> Media.get_media_item!(media_item.id) end
    end

    test "delete_media_items/2 returns count and error count", %{library_path: lp} do
      item1 = movie_with_file(lp, "a.mkv", "data")
      item2 = movie_with_file(lp, "b.mkv", "data")

      assert {:ok, 2, 0} =
               Media.delete_media_items([item1.id, item2.id], delete_files: true)
    end

    test "delete_media_items/2 with delete_files: false reports zero errors", %{library_path: lp} do
      item = movie_with_file(lp, "keep.mkv", "data")
      abs = Path.join(lp.path, "keep.mkv")

      assert {:ok, 1, 0} = Media.delete_media_items([item.id])
      assert File.exists?(abs)
    end
  end

  describe "partition_for_auto_search/1 with movies" do
    test "returns a movie with no files and no downloads" do
      movie = insert(:media_item, type: "movie")

      assert {[found], 0} = Media.partition_for_auto_search([movie.id])
      assert found.id == movie.id
    end

    test "skips a movie with an untrashed media file" do
      movie = insert(:media_item, type: "movie")
      insert(:media_file, media_item: movie, episode: nil)

      assert {[], 1} = Media.partition_for_auto_search([movie.id])
    end

    test "returns a movie whose only media file is trashed" do
      movie = insert(:media_item, type: "movie")

      insert(:media_file,
        media_item: movie,
        episode: nil,
        trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {[found], 0} = Media.partition_for_auto_search([movie.id])
      assert found.id == movie.id
    end

    test "skips a movie with an occupying download" do
      movie = insert(:media_item, type: "movie")
      insert(:download, media_item: movie)

      assert {[], 1} = Media.partition_for_auto_search([movie.id])
    end

    test "returns a movie whose only download failed terminally" do
      movie = insert(:media_item, type: "movie")

      insert(:download,
        media_item: movie,
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        import_next_retry_at: nil
      )

      assert {[found], 0} = Media.partition_for_auto_search([movie.id])
      assert found.id == movie.id
    end

    test "returns an unmonitored movie with no files" do
      movie = insert(:media_item, type: "movie", monitored: false)

      assert {[found], 0} = Media.partition_for_auto_search([movie.id])
      assert found.id == movie.id
    end

    test "ignores ids that do not exist" do
      assert {[], 0} = Media.partition_for_auto_search([Ecto.UUID.generate()])
    end

    test "returns an empty result for an empty id list" do
      assert {[], 0} = Media.partition_for_auto_search([])
    end
  end

  describe "partition_for_auto_search/1 with TV shows" do
    setup do
      %{yesterday: Date.add(Date.utc_today(), -1), tomorrow: Date.add(Date.utc_today(), 1)}
    end

    test "returns a show with an aired monitored episode that has no file", %{
      yesterday: yesterday
    } do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday)

      assert {[found], 0} = Media.partition_for_auto_search([show.id])
      assert found.id == show.id
    end

    test "skips a show whose only aired episode already has a file", %{yesterday: yesterday} do
      show = insert(:tv_show)
      episode = insert(:episode, media_item: show, air_date: yesterday)
      insert(:media_file, episode: episode, media_item: nil)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "returns a show whose episode file is trashed", %{yesterday: yesterday} do
      show = insert(:tv_show)
      episode = insert(:episode, media_item: show, air_date: yesterday)

      insert(:media_file,
        episode: episode,
        media_item: nil,
        trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {[found], 0} = Media.partition_for_auto_search([show.id])
      assert found.id == show.id
    end

    test "skips a show whose only missing episode has not aired", %{tomorrow: tomorrow} do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: tomorrow)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "skips a show whose only missing episode has no air date" do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: nil)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "skips a show whose only missing episode is unmonitored", %{yesterday: yesterday} do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday, monitored: false)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "skips an unmonitored show with missing episodes", %{yesterday: yesterday} do
      show = insert(:tv_show, monitored: false)
      insert(:episode, media_item: show, air_date: yesterday)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "skips a show whose only missing episode has an occupying download", %{
      yesterday: yesterday
    } do
      show = insert(:tv_show)
      episode = insert(:episode, media_item: show, air_date: yesterday)
      insert(:download, media_item: show, episode: episode)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "skips a show whose only missing episode is a special", %{yesterday: yesterday} do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday, season_number: 0)

      assert {[], 1} = Media.partition_for_auto_search([show.id])
    end

    test "returns a show with a missing special when specials are monitored", %{
      yesterday: yesterday
    } do
      original = Application.get_env(:mydia, :episode_monitor, [])

      Application.put_env(
        :mydia,
        :episode_monitor,
        Keyword.put(original, :monitor_special_episodes, true)
      )

      on_exit(fn -> Application.put_env(:mydia, :episode_monitor, original) end)

      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday, season_number: 0)

      assert {[found], 0} = Media.partition_for_auto_search([show.id])
      assert found.id == show.id
    end

    test "returns a show once even when several episodes are missing", %{yesterday: yesterday} do
      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday, episode_number: 1)
      insert(:episode, media_item: show, air_date: yesterday, episode_number: 2)

      assert {[found], 0} = Media.partition_for_auto_search([show.id])
      assert found.id == show.id
    end

    test "counts movies and shows together", %{yesterday: yesterday} do
      movie = insert(:media_item, type: "movie")
      complete_movie = insert(:media_item, type: "movie")
      insert(:media_file, media_item: complete_movie, episode: nil)

      show = insert(:tv_show)
      insert(:episode, media_item: show, air_date: yesterday)

      complete_show = insert(:tv_show)
      complete_episode = insert(:episode, media_item: complete_show, air_date: yesterday)
      insert(:media_file, episode: complete_episode, media_item: nil)

      ids = [movie.id, complete_movie.id, show.id, complete_show.id]
      {items, skipped} = Media.partition_for_auto_search(ids)

      assert skipped == 2
      assert Enum.sort(Enum.map(items, & &1.id)) == Enum.sort([movie.id, show.id])
    end
  end

  describe "library_status_for_tmdb_ids/2" do
    import Mydia.MediaFixtures

    test "matches movies by tmdb id and type" do
      movie = media_item_fixture(%{type: "movie", tmdb_id: 603, monitored: true})

      status = Media.library_status_for_tmdb_ids([603, 999], "movie")

      assert %{in_library: true, monitored: true, type: "movie", id: id} = status[603]
      assert id == movie.id
      refute Map.has_key?(status, 999)
    end

    test "does not match a tv show when asked for movies" do
      media_item_fixture(%{type: "tv_show", tmdb_id: 603})

      status = Media.library_status_for_tmdb_ids([603], "movie")

      refute Map.has_key?(status, 603)
    end

    test "matches tv shows when asked for tv_show" do
      show = media_item_fixture(%{type: "tv_show", tmdb_id: 1396})

      status = Media.library_status_for_tmdb_ids([1396], "tv_show")

      assert status[1396].id == show.id
    end

    test "returns an empty map for an empty id list" do
      assert Media.library_status_for_tmdb_ids([], "movie") == %{}
    end
  end

  describe "list_media_items/1 :ids filter" do
    import Mydia.MediaFixtures

    test "returns only the requested ids" do
      a = media_item_fixture(%{type: "movie", title: "A"})
      _b = media_item_fixture(%{type: "movie", title: "B"})
      c = media_item_fixture(%{type: "movie", title: "C"})

      results = Media.list_media_items(ids: [a.id, c.id])

      assert length(results) == 2
      assert Enum.map(results, & &1.id) |> Enum.sort() == Enum.sort([a.id, c.id])
    end

    test "returns an empty list for an empty id list" do
      media_item_fixture(%{type: "movie"})

      assert Media.list_media_items(ids: []) == []
    end
  end

  describe "list_library_items_page/1" do
    import Mydia.MediaFixtures

    test "marks a movie with an untrashed file as owned" do
      movie = media_item_fixture(%{type: "movie", title: "Owned Movie"})
      _file = media_file_fixture(%{media_item_id: movie.id})

      assert [row] = Enum.filter(Media.list_library_items_page(), &(&1.id == movie.id))
      assert row.owned
      assert row.type == "movie"
    end

    test "marks a movie with no files as not owned" do
      movie = media_item_fixture(%{type: "movie", title: "Catalogued Only"})

      assert [row] = Enum.filter(Media.list_library_items_page(), &(&1.id == movie.id))
      refute row.owned
    end

    test "marks a show owned when any episode has an untrashed file" do
      show = media_item_fixture(%{type: "tv_show", title: "Owned Show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
      _file = media_file_fixture(%{episode_id: episode.id})

      assert [row] = Enum.filter(Media.list_library_items_page(), &(&1.id == show.id))
      assert row.owned
    end

    test "ignores trashed files when deciding ownership" do
      movie = media_item_fixture(%{type: "movie", title: "Trashed Only"})

      _file =
        media_file_fixture(%{
          media_item_id: movie.id,
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert [row] = Enum.filter(Media.list_library_items_page(), &(&1.id == movie.id))
      refute row.owned
    end

    test "carries the keyset fields the host cursor needs" do
      movie = media_item_fixture(%{type: "movie", title: "Cursor Fields"})

      assert [row] = Enum.filter(Media.list_library_items_page(), &(&1.id == movie.id))
      assert %DateTime{} = row.updated_at
      assert is_binary(row.id)
    end
  end

  describe "find_by_external_ids/2" do
    test "falls through to tvdb when the imdb id matches nothing" do
      {:ok, show} =
        Media.create_media_item(
          %{title: "Cascade Show", type: "tv_show", tvdb_id: 378_982},
          skip_episode_refresh: true
        )

      # A Plex episode carries all three ids on its show; only tvdb is local.
      # Strings are what Plex GUIDs parse to, and Ecto casts them for the
      # integer column.
      assert %{id: id} = Media.find_by_external_ids(%{imdb: "tt-absent", tvdb: "378982"})
      assert id == show.id
    end

    test "falls through to tmdb when imdb and tvdb both miss" do
      {:ok, show} =
        Media.create_media_item(
          %{title: "Tmdb Show", type: "tv_show", tmdb_id: 108_255},
          skip_episode_refresh: true
        )

      assert %{id: id} =
               Media.find_by_external_ids(%{
                 imdb: "tt-absent",
                 tvdb: "999999",
                 tmdb: "108255"
               })

      assert id == show.id
    end

    test "returns nil when no ids are given" do
      assert Media.find_by_external_ids(%{}) == nil
    end

    test "returns nil when nothing matches" do
      assert Media.find_by_external_ids(%{imdb: "tt-nope", tvdb: "424242", tmdb: "424243"}) == nil
    end

    test "a wrong-type match does not short-circuit the cascade" do
      {:ok, _decoy} =
        Media.create_media_item(%{
          title: "Decoy Movie",
          type: "movie",
          year: 2024,
          imdb_id: "tt777"
        })

      {:ok, show} =
        Media.create_media_item(
          %{title: "Real Show", type: "tv_show", tvdb_id: 777},
          skip_episode_refresh: true
        )

      assert %{id: id} =
               Media.find_by_external_ids(%{imdb: "tt777", tvdb: "777"}, type: "tv_show")

      assert id == show.id
    end

    test "returns nil when the only match is the wrong type" do
      {:ok, _movie} =
        Media.create_media_item(%{
          title: "Only Movie",
          type: "movie",
          year: 2024,
          imdb_id: "tt888"
        })

      assert Media.find_by_external_ids(%{imdb: "tt888"}, type: "tv_show") == nil
    end

    test "arity-1 calls still resolve" do
      {:ok, movie} =
        Media.create_media_item(%{
          title: "Legacy Caller",
          type: "movie",
          year: 2024,
          imdb_id: "tt999"
        })

      assert %{id: id} = Media.find_by_external_ids(%{imdb: "tt999"})
      assert id == movie.id
    end

    test "raises ArgumentError on an unrecognised :type" do
      assert_raise ArgumentError, fn ->
        Media.find_by_external_ids(%{imdb: "tt1"}, type: "tvshow")
      end
    end

    test "type: nil applies no filter" do
      {:ok, movie} =
        Media.create_media_item(%{
          title: "Untyped Filter",
          type: "movie",
          year: 2024,
          imdb_id: "tt-untyped"
        })

      assert %{id: id} = Media.find_by_external_ids(%{imdb: "tt-untyped"}, type: nil)
      assert id == movie.id
    end

    test "a duplicate match deterministically picks the earliest inserted row" do
      # imdb_id carries no unique index (unlike tvdb_id/tmdb_id), so this is
      # the id that can actually collide. Without an order_by, PostgreSQL does
      # not guarantee LIMIT 1 returns insertion order, and since the crawl now
      # repeats daily a nondeterministic pick could flip the stored mapping
      # between runs.
      {:ok, older} =
        Media.create_media_item(%{
          title: "Older Duplicate",
          type: "tv_show",
          imdb_id: "tt-dup-order"
        })

      {:ok, _newer} =
        Media.create_media_item(%{
          title: "Newer Duplicate",
          type: "tv_show",
          imdb_id: "tt-dup-order"
        })

      assert %{id: id} = Media.find_by_external_ids(%{imdb: "tt-dup-order"})
      assert id == older.id
    end

    test "a non-numeric tvdb id falls through to tmdb instead of raising" do
      {:ok, show} =
        Media.create_media_item(
          %{title: "Tmdb Fallback Show", type: "tv_show", tmdb_id: 555_555},
          skip_episode_refresh: true
        )

      assert %{id: id} = Media.find_by_external_ids(%{tvdb: "not-a-number", tmdb: "555555"})
      assert id == show.id
    end

    test "a non-numeric tmdb id does not raise and returns nil" do
      assert Media.find_by_external_ids(%{tmdb: "not-a-number"}) == nil
    end

    test "a tvdb id with trailing garbage does not match" do
      {:ok, _show} =
        Media.create_media_item(
          %{title: "Trailing Garbage Show", type: "tv_show", tvdb_id: 123},
          skip_episode_refresh: true
        )

      assert Media.find_by_external_ids(%{tvdb: "123abc"}) == nil
    end

    test "a numeric tvdb string still matches" do
      {:ok, show} =
        Media.create_media_item(
          %{title: "Numeric String Show", type: "tv_show", tvdb_id: 42},
          skip_episode_refresh: true
        )

      assert %{id: id} = Media.find_by_external_ids(%{tvdb: "42"})
      assert id == show.id
    end

    test "an integer tvdb id still matches" do
      {:ok, show} =
        Media.create_media_item(
          %{title: "Integer Id Show", type: "tv_show", tvdb_id: 43},
          skip_episode_refresh: true
        )

      assert %{id: id} = Media.find_by_external_ids(%{tvdb: 43})
      assert id == show.id
    end
  end
end
