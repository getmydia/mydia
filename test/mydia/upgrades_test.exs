defmodule Mydia.UpgradesTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

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
        codec: "H.264 (High)",
        audio_codec: "AAC Stereo",
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
        codec: "H.264 (High)",
        audio_codec: "AAC Stereo",
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
        codec: "HEVC",
        audio_codec: "TrueHD 7.1",
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
        codec: "H.264",
        audio_codec: "AAC Stereo",
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

    test "respects the limit" do
      profile = upgradeable_profile()
      for _ <- 1..3, do: analyzed_episode_file(profile)

      assert length(Upgrades.eligible_episodes(2)) == 2
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
end
