defmodule Mydia.UpgradesTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Upgrades

  defp upgradeable_profile do
    quality_profile_fixture(%{
      name: "Upgradeable #{System.unique_integer([:positive])}",
      upgrades_allowed: true,
      upgrade_until_score: 100,
      min_upgrade_margin: 5,
      quality_standards: %{preferred_resolutions: ["2160p"]}
    })
  end

  defp analyzed_movie_file(profile) do
    movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

    file =
      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "720p",
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{audio_codec_raw: "AAC Stereo"},
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        quality_profile: profile
      )

    {movie, file}
  end

  defp analyzed_episode_file(profile) do
    show = insert(:tv_show, monitored: true, quality_profile: profile)
    episode = insert(:episode, media_item: show, monitored: true)

    file =
      insert(:media_file,
        episode: episode,
        resolution: "720p",
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{audio_codec_raw: "AAC Stereo"},
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        quality_profile: profile
      )

    {episode, file}
  end

  describe "eligible_movies/1" do
    test "returns a below-cutoff movie with its file and profile" do
      profile = upgradeable_profile()
      {movie, _file} = analyzed_movie_file(profile)

      assert [%{media_item: found}] = Upgrades.eligible_movies(10)
      assert found.id == movie.id
    end

    test "excludes a movie whose only file was never analyzed" do
      profile = upgradeable_profile()
      movie = insert(:media_item, type: "movie", monitored: true)

      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "720p",
        analyzed_at: nil,
        quality_profile: profile
      )

      assert [] = Upgrades.eligible_movies(10)
    end

    test "excludes a movie with an occupying download" do
      profile = upgradeable_profile()
      {movie, _file} = analyzed_movie_file(profile)
      insert(:download, media_item: movie)

      assert [] = Upgrades.eligible_movies(10)
    end

    test "orders never-checked items before previously-checked ones" do
      profile = upgradeable_profile()
      {old, _} = analyzed_movie_file(profile)

      {:ok, _} =
        old
        |> Ecto.Changeset.change(last_upgrade_check_at: ~U[2026-01-01 00:00:00Z])
        |> Repo.update()

      {fresh, _} = analyzed_movie_file(profile)

      assert [%{media_item: first} | _] = Upgrades.eligible_movies(10)
      assert first.id == fresh.id
    end

    test "respects the limit" do
      profile = upgradeable_profile()
      for _ <- 1..3, do: analyzed_movie_file(profile)

      assert length(Upgrades.eligible_movies(2)) == 2
    end

    test "overfetches so an eligible item is not starved by an above-cutoff neighbor ahead of it in staleness order" do
      profile =
        quality_profile_fixture(%{
          name: "Overfetch #{System.unique_integer([:positive])}",
          upgrades_allowed: true,
          upgrade_until_score: 80,
          min_upgrade_margin: 5,
          quality_standards: %{
            preferred_resolutions: ["2160p"],
            preferred_video_codecs: ["h265"],
            preferred_audio_codecs: ["truehd"]
          }
        })

      # Already meets every preference (score ~90.5) - above cutoff, must be
      # filtered out. Never checked, so it sorts first (nulls first).
      already_good = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

      insert(:media_file,
        media_item: already_good,
        episode: nil,
        resolution: "2160p",
        codec: "hevc",
        audio_codec: "truehd",
        metadata: %FileMetadata{audio_codec_raw: "TrueHD 7.1"},
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        quality_profile: profile
      )

      # Meets none of the preferences (score ~44.0) - below cutoff, the only
      # real candidate. Stamped with a real timestamp so it sorts strictly
      # after the never-checked row above.
      needs_upgrade =
        insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

      insert(:media_file,
        media_item: needs_upgrade,
        episode: nil,
        resolution: "480p",
        codec: "h264",
        audio_codec: "aac",
        metadata: %FileMetadata{audio_codec_raw: "AAC Stereo"},
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        quality_profile: profile
      )

      {:ok, _} =
        needs_upgrade
        |> Ecto.Changeset.change(last_upgrade_check_at: ~U[2020-01-01 00:00:00Z])
        |> Repo.update()

      # A naive `limit(1)` SQL fetch would return only `already_good` (it
      # sorts first) and, once filtered, yield []. The @overfetch multiplier
      # must pull `needs_upgrade` into the candidate pool too.
      assert [%{media_item: found}] = Upgrades.eligible_movies(1)
      assert found.id == needs_upgrade.id
    end
  end

  describe "eligible_movies/1 backoff namespacing" do
    # A "movie" backoff row is written by MovieSearch's all_monitored/specific
    # paths, which only ever search movies *without* a file. A movie's file
    # state changes over time (manual import, external client, library
    # rescan), so by the time this movie has a file and is upgrade-eligible,
    # a stale "movie" backoff row from before the file existed must not
    # suppress it - that row answers a different question ("can we search for
    # this movie's missing file") than eligible_movies/1 is asking ("can we
    # search for an upgrade to this movie's file"). See task-7 review finding
    # 1: before this test existed, eligible_movies/1 excluded on the
    # resource_type: "movie" bucket - the same one MovieSearch's other modes
    # write to - so this row would have wrongly suppressed the movie below.
    test "a fileless-search backoff on the same movie does not suppress its upgrade eligibility" do
      profile = upgradeable_profile()
      {movie, _file} = analyzed_movie_file(profile)

      {:ok, _backoff} = Mydia.Search.record_failure("movie", movie.id, "no_results")

      assert [%{media_item: found}] = Upgrades.eligible_movies(10)
      assert found.id == movie.id
    end

    test "an upgrade-search backoff does suppress the movie until it expires" do
      profile = upgradeable_profile()
      {movie, _file} = analyzed_movie_file(profile)

      {:ok, _backoff} = Mydia.Search.record_failure("movie_upgrade", movie.id, "no_upgrade_found")

      assert [] = Upgrades.eligible_movies(10)
    end
  end

  describe "eligible_episodes/1" do
    test "returns a below-cutoff episode with its file, profile, and score" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)

      assert [%{episode: found, score: score}] = Upgrades.eligible_episodes(10)
      assert found.id == episode.id
      assert is_float(score)
    end

    test "excludes an episode whose only file was never analyzed" do
      profile = upgradeable_profile()
      show = insert(:tv_show, monitored: true)
      episode = insert(:episode, media_item: show, monitored: true)

      insert(:media_file,
        episode: episode,
        resolution: "720p",
        analyzed_at: nil,
        quality_profile: profile
      )

      assert [] = Upgrades.eligible_episodes(10)
    end

    test "excludes an episode with an occupying download" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)
      insert(:download, media_item: episode.media_item, episode: episode)

      assert [] = Upgrades.eligible_episodes(10)
    end

    # Whole-branch review finding 2: a season-pack download carries
    # media_item_id plus metadata.season_pack and *no* episode_id, so the
    # occupying_episode_ids/0 subquery cannot see it. Without this filter the
    # sweep keeps re-searching (and, once the season drops under the 70% pack
    # threshold, individually re-grabbing) episodes the in-flight pack already
    # covers. The missing-file path has handled this since it was written.
    test "excludes an episode covered by an active season-pack download" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)

      insert(:download,
        media_item: episode.media_item,
        episode: nil,
        metadata: %{"season_pack" => true, "season_number" => episode.season_number}
      )

      assert [] = Upgrades.eligible_episodes(10)
    end

    test "keeps an episode when the active season pack is for a different season" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)

      insert(:download,
        media_item: episode.media_item,
        episode: nil,
        metadata: %{"season_pack" => true, "season_number" => episode.season_number + 1}
      )

      assert [%{episode: found}] = Upgrades.eligible_episodes(10)
      assert found.id == episode.id
    end

    test "orders never-checked items before previously-checked ones" do
      profile = upgradeable_profile()
      {old, _} = analyzed_episode_file(profile)

      {:ok, _} =
        old
        |> Ecto.Changeset.change(last_upgrade_check_at: ~U[2026-01-01 00:00:00Z])
        |> Repo.update()

      {fresh, _} = analyzed_episode_file(profile)

      assert [%{episode: first} | _] = Upgrades.eligible_episodes(10)
      assert first.id == fresh.id
    end

    # Unlike eligible_movies/1, `limit` is not a cap on the result count: a
    # season pack can turn many episodes into one search, so truncating the
    # result list to `limit` risks splitting a season's below-cutoff
    # episodes across the boundary and corrupting the pack-threshold
    # percentage (see the moduledoc on eligible_episodes/1). Every
    # below-cutoff episode within the SQL-layer over-fetch page is returned.
    test "does not truncate to the limit, so a whole season can stay together" do
      profile = upgradeable_profile()
      for _ <- 1..3, do: analyzed_episode_file(profile)

      assert length(Upgrades.eligible_episodes(2)) == 3
    end

    test "still bounds results to the SQL-layer over-fetch page" do
      profile = upgradeable_profile()
      for _ <- 1..12, do: analyzed_episode_file(profile)

      # limit: 2 sizes an over-fetch page of 2 * 5 = 10 raw rows; every one
      # of them is below cutoff here, so exactly 10 (not all 12) come back.
      assert length(Upgrades.eligible_episodes(2)) == 10
    end
  end

  describe "eligible_episodes/1 backoff namespacing" do
    # Mirrors "eligible_movies/1 backoff namespacing" above: a "episode"
    # backoff row is written by TVShowSearch's missing-file search paths
    # (specific/season/show/all_monitored), which only ever search episodes
    # *without* a file. An episode's file state changes over time (manual
    # import, external client, library rescan), so by the time this episode
    # has a file and is upgrade-eligible, a stale "episode" backoff row from
    # before the file existed must not suppress it.
    test "a fileless-search backoff on the same episode does not suppress its upgrade eligibility" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)

      {:ok, _backoff} = Mydia.Search.record_failure("episode", episode.id, "no_results")

      assert [%{episode: found}] = Upgrades.eligible_episodes(10)
      assert found.id == episode.id
    end

    test "an upgrade-search backoff does suppress the episode until it expires" do
      profile = upgradeable_profile()
      {episode, _file} = analyzed_episode_file(profile)

      {:ok, _backoff} =
        Mydia.Search.record_failure("episode_upgrade", episode.id, "no_upgrade_found")

      assert [] = Upgrades.eligible_episodes(10)
    end
  end

  describe "stamp_checked/2" do
    test "sets last_upgrade_check_at on the given movies" do
      profile = upgradeable_profile()
      {movie, _} = analyzed_movie_file(profile)

      Upgrades.stamp_checked(:movie, [movie.id])

      assert Repo.reload!(movie).last_upgrade_check_at
    end
  end

  # Task 9 introduces this lookup so `Mydia.Jobs.MediaImport` can resolve
  # what a newly imported upgrade file supersedes: the "current file" this
  # module already scores everywhere else, for one specific media item or
  # episode instead of the whole eligibility sweep.
  describe "current_best_file_id/2" do
    test "returns the current file's id for a movie" do
      profile = upgradeable_profile()
      {movie, file} = analyzed_movie_file(profile)

      assert Upgrades.current_best_file_id(movie.id, nil) == file.id
    end

    test "returns the current file's id for an episode" do
      profile = upgradeable_profile()
      {episode, file} = analyzed_episode_file(profile)

      assert Upgrades.current_best_file_id(nil, episode.id) == file.id
    end

    test "returns nil when the movie has no files at all" do
      profile = upgradeable_profile()
      movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

      assert Upgrades.current_best_file_id(movie.id, nil) == nil
    end

    test "returns nil when the episode has no files at all" do
      profile = upgradeable_profile()
      show = insert(:tv_show, monitored: true, quality_profile: profile)
      episode = insert(:episode, media_item: show, monitored: true)

      assert Upgrades.current_best_file_id(nil, episode.id) == nil
    end

    test "excludes a trashed file, even when it's the only one" do
      profile = upgradeable_profile()
      {movie, file} = analyzed_movie_file(profile)

      {:ok, _} =
        file
        |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      assert Upgrades.current_best_file_id(movie.id, nil) == nil
    end

    test "excludes an unanalyzed file, even when it's the only one" do
      profile = upgradeable_profile()
      movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "720p",
        analyzed_at: nil,
        quality_profile: profile
      )

      assert Upgrades.current_best_file_id(movie.id, nil) == nil
    end

    test "picks the highest-scoring file when several exist for the same movie" do
      profile = upgradeable_profile()
      movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "480p",
        codec: "h264",
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        quality_profile: profile
      )

      better =
        insert(:media_file,
          media_item: movie,
          episode: nil,
          resolution: "2160p",
          codec: "hevc",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          quality_profile: profile
        )

      assert Upgrades.current_best_file_id(movie.id, nil) == better.id
    end

    test "returns nil when the media item has no quality profile and no instance default" do
      movie = insert(:media_item, type: "movie", monitored: true)

      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "1080p",
        analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert Upgrades.current_best_file_id(movie.id, nil) == nil
    end

    test "returns nil when neither a media_item_id nor an episode_id is given" do
      assert Upgrades.current_best_file_id(nil, nil) == nil
    end
  end
end
