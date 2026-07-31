defmodule Mydia.Jobs.UpgradeSweepTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.UpgradeSweep

  setup do
    original = Application.get_env(:mydia, :runtime_config)
    put_upgrades_config(sweep_enabled: true, sweep_batch_size: 10)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  # Overrides only the :upgrades embed of the layered runtime config
  # (Mydia.Config.get().upgrades), which is what UpgradeSweep.enabled?/0 and
  # .batch_size/0 actually read. Setting the old flat
  # Application.put_env(:mydia, :upgrade_sweep_enabled, ...) key here would
  # be silently ignored by the job — see the comments on enabled?/0 and
  # batch_size/0 in lib/mydia/jobs/upgrade_sweep.ex.
  defp put_upgrades_config(attrs) do
    defaults = Mydia.Config.Schema.defaults()
    upgrades = struct(defaults.upgrades, attrs)
    Application.put_env(:mydia, :runtime_config, %{defaults | upgrades: upgrades})
  end

  defp eligible_movie do
    profile =
      quality_profile_fixture(%{
        name: "Sweep #{System.unique_integer([:positive])}",
        upgrades_allowed: true,
        upgrade_until_score: 100,
        quality_standards: %{preferred_resolutions: ["2160p"]}
      })

    movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

    insert(:media_file,
      media_item: movie,
      episode: nil,
      resolution: "720p",
      codec: "H.264 (High)",
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      quality_profile: profile
    )

    movie
  end

  # NOTE: this proves stamping happens when a candidate's enqueue succeeds —
  # the only case this test suite can construct. It does NOT, by itself,
  # prove the item is stamped when its enqueue *fails* (the actual
  # anti-starvation guarantee decisions #2/#3 in the task brief describe):
  # every candidate here succeeds, since Repo.insert/1 (the fallback
  # insert_job/1 uses under config/test.exs's engine: false) never fails for
  # a well-formed MovieSearch changeset in this codebase — there is no FK or
  # unique DB constraint tied to the business ids carried in `args`, and this
  # project has no mocking library wired up to stub Repo.insert/1 or
  # Oban.insert/1. See the comment on enqueue_movie/1 in
  # lib/mydia/jobs/upgrade_sweep.ex for the full reasoning trail.
  test "stamps the candidate it successfully enqueues" do
    movie = eligible_movie()

    assert {:ok, _} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(movie).last_upgrade_check_at
  end

  test "does nothing when the sweep is disabled" do
    movie = eligible_movie()
    put_upgrades_config(sweep_enabled: false, sweep_batch_size: 10)

    assert {:ok, :disabled} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    refute Repo.reload!(movie).last_upgrade_check_at
  end

  test "never enqueues more searches than the batch size" do
    for _ <- 1..5, do: eligible_movie()
    put_upgrades_config(sweep_enabled: true, sweep_batch_size: 2)

    assert {:ok, %{searches: 2}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
  end

  defp show_with_profile do
    profile =
      quality_profile_fixture(%{
        name: "Sweep #{System.unique_integer([:positive])}",
        upgrades_allowed: true,
        upgrade_until_score: 90,
        quality_standards: %{preferred_resolutions: ["2160p"]}
      })

    show = insert(:tv_show, monitored: true, quality_profile: profile)
    {show, profile}
  end

  # Resolution "720p" against preferred_resolutions ["2160p"] scores 84.5
  # overall (see below_cutoff/above_cutoff score derivation in the task
  # report) — below the fixture's upgrade_until_score: 90, so this file is
  # eligible for upgrade.
  defp below_cutoff_episode(show, profile, season_number, episode_number) do
    episode =
      insert(:episode,
        media_item: show,
        season_number: season_number,
        episode_number: episode_number,
        monitored: true
      )

    insert(:media_file,
      episode: episode,
      resolution: "720p",
      codec: "H.264 (High)",
      audio_codec: "AAC Stereo",
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      quality_profile: profile
    )

    episode
  end

  # Resolution "4K" (canonicalizes to "2160p", the preferred resolution) plus
  # hdr_format "Dolby Vision" scores 94.0 overall — above the fixture's
  # upgrade_until_score: 90, so Upgrades.eligible_episodes/1 never returns
  # this candidate. It exists purely so the season's total episode count
  # (read from the DB by TVShowSearch.should_prefer_season_pack?/3, not from
  # the below-cutoff candidate set) reflects a realistic full season.
  defp above_cutoff_episode(show, profile, season_number, episode_number) do
    episode =
      insert(:episode,
        media_item: show,
        season_number: season_number,
        episode_number: episode_number,
        monitored: true
      )

    insert(:media_file,
      episode: episode,
      resolution: "4K",
      codec: "H.264 (High)",
      audio_codec: "AAC Stereo",
      hdr_format: "Dolby Vision",
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      quality_profile: profile
    )

    episode
  end

  describe "episode routing" do
    test "a season with most episodes below cutoff costs one pack search" do
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 1}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    end

    test "a season with few episodes below cutoff costs one search each" do
      {show, profile} = show_with_profile()
      for n <- 1..2, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 3..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 2}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    end

    # Proves the budget genuinely governs episode search cost, not just
    # counts candidates: with an unconstrained budget this season would
    # qualify for a single pack search (8/10 below cutoff = 80% >= 70%).
    # Capped at batch_size: 5, Upgrades.eligible_episodes/1 can only surface
    # 5 of the 8 below-cutoff episodes, so should_prefer_season_pack?/3 sees
    # 5/10 = 50% (< 70%) and correctly routes to individual searches —
    # capped at exactly the batch size, not the full 8.
    test "caps episode searches at the batch size even when the full season would pack" do
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      put_upgrades_config(sweep_enabled: true, sweep_batch_size: 5)

      assert {:ok, %{searches: 5}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
      assert Repo.aggregate(Oban.Job, :count) == 5
    end
  end
end
