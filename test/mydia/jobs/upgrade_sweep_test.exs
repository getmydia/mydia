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
        quality_standards: %{
          preferred_resolutions: ["2160p"],
          preferred_audio_channels: ["5.1"]
        }
      })

    show = insert(:tv_show, monitored: true, quality_profile: profile)
    {show, profile}
  end

  # Resolution "720p" against preferred_resolutions ["2160p"] and audio
  # channels "2.0" ("AAC Stereo") against preferred_audio_channels ["5.1"]
  # score 75.5 overall by default — below the fixture's
  # upgrade_until_score: 90, so this file is eligible for upgrade. `opts`
  # overrides the media_file attrs, e.g. `audio_codec: "AAC 5.1"` to make one
  # fixture distinctly higher-scoring (84.5, still below cutoff) than its
  # siblings, for tests that need a discriminating "best in the season"
  # target. See the task report for the full score derivation.
  defp below_cutoff_episode(show, profile, season_number, episode_number, opts \\ []) do
    episode =
      insert(:episode,
        media_item: show,
        season_number: season_number,
        episode_number: episode_number,
        monitored: true
      )

    file =
      insert(
        :media_file,
        Keyword.merge(
          [
            episode: episode,
            resolution: "720p",
            codec: "H.264 (High)",
            audio_codec: "AAC Stereo",
            size: 2 * 1024 * 1024 * 1024,
            analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            quality_profile: profile
          ],
          opts
        )
      )

    {episode, file}
  end

  # Resolution "4K" (canonicalizes to "2160p", the preferred resolution),
  # audio channels "5.1" (preferred), plus hdr_format "Dolby Vision" score
  # 94.0 overall — above the fixture's upgrade_until_score: 90, so
  # Upgrades.eligible_episodes/1 never returns this candidate. It exists
  # purely so the season's total episode count (read from the DB by
  # TVShowSearch.should_prefer_season_pack?/3, not from the below-cutoff
  # candidate set) reflects a realistic full season.
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
      audio_codec: "AAC 5.1",
      hdr_format: "Dolby Vision",
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      quality_profile: profile
    )

    episode
  end

  defp tv_show_search_jobs do
    Enum.filter(Repo.all(Oban.Job), &(&1.worker == "Mydia.Jobs.TVShowSearch"))
  end

  defp movie_search_jobs do
    Enum.filter(Repo.all(Oban.Job), &(&1.worker == "Mydia.Jobs.MovieSearch"))
  end

  describe "episode routing" do
    test "a season with most episodes below cutoff costs one pack search" do
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 1}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})
    end

    test "a season with few episodes below cutoff costs one search each" do
      {show, profile} = show_with_profile()
      for n <- 1..2, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 3..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 2}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})
    end

    # A season pack search still costs exactly one search even when the
    # configured batch size is smaller than the season, because
    # Upgrades.eligible_episodes/1 no longer truncates its result list to
    # the search budget (finding 2 fix) — it only sizes a generous SQL-layer
    # over-fetch page, so the full below-cutoff season stays visible to
    # should_prefer_season_pack?/3 regardless of how small sweep_batch_size
    # is. Before that fix this asserted `searches: 5` — the batch-size cap
    # itself, not the desired single-pack outcome — which encoded the
    # distortion finding 2 flagged as its own contract.
    test "packs the whole season into one search even when the batch size is smaller than the season" do
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      put_upgrades_config(sweep_enabled: true, sweep_batch_size: 5)

      assert {:ok, %{searches: 1}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})
    end

    test "routes the pack search to the best-scoring below-cutoff file in the season" do
      {show, profile} = show_with_profile()
      for n <- 1..7, do: below_cutoff_episode(show, profile, 1, n)
      {_episode, best_file} = below_cutoff_episode(show, profile, 1, 8, audio_codec: "AAC 5.1")
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 1}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      assert [job] = tv_show_search_jobs()
      assert job.args["mode"] == "upgrade_season"
      assert job.args["media_item_id"] == show.id
      assert job.args["season_number"] == 1
      assert job.args["media_file_id"] == best_file.id
    end

    test "routes individual searches with each episode's own file" do
      {show, profile} = show_with_profile()
      {ep1, file1} = below_cutoff_episode(show, profile, 1, 1)
      {ep2, file2} = below_cutoff_episode(show, profile, 1, 2, audio_codec: "AAC 5.1")
      for n <- 3..10, do: above_cutoff_episode(show, profile, 1, n)

      assert {:ok, %{searches: 2}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      jobs = tv_show_search_jobs()
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args["mode"] == "upgrade_episode"))

      pairs = Map.new(jobs, &{&1.args["episode_id"], &1.args["media_file_id"]})
      assert pairs[ep1.id] == file1.id
      assert pairs[ep2.id] == file2.id
    end

    # Proves the search-cost budget genuinely halts mid-iteration and skips
    # a fetched-but-unaffordable group entirely, rather than merely being
    # unreachable dead code — and specifically that it previews each group's
    # cost *before* enqueuing rather than checking only the running total
    # after the fact (finding 5). A pack group cannot expose this: its cost
    # is always exactly 1 regardless of size, so "spent >= budget" and
    # "spent + 1 > budget" are the same check. It takes a multi-episode
    # *individual*-mode group (cost > 1) to tell them apart — mirrors
    # finding 5's own example (three groups of 4, budget 10): three shows
    # each with 4 of 10 episodes below cutoff (40% < 70% -> individual, cost
    # 4 each). The old post-hoc check would let all three run (4 -> 8 -> 12,
    # overspending by 2); the fix previews the third group's cost against
    # the remaining budget and skips it whole (4 -> 8 -> halt).
    test "halts before a group that would push spending past the budget" do
      for _ <- 1..3 do
        {show, profile} = show_with_profile()
        for n <- 1..4, do: below_cutoff_episode(show, profile, 1, n)
        for n <- 5..10, do: above_cutoff_episode(show, profile, 1, n)
      end

      put_upgrades_config(sweep_enabled: true, sweep_batch_size: 10)

      assert {:ok, %{searches: 8}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      assert length(tv_show_search_jobs()) == 8
    end
  end

  describe "lead alternation" do
    # Reproduces the starvation finding 1 describes: a library with at
    # least sweep_batch_size below-cutoff movies leaves 0 budget for
    # episodes on a movies-led run. Confirms the trailing type (episodes
    # here) gets nothing this run, then confirms an opposite-lead run does
    # give episodes their turn — proving alternation, not just "some
    # searches happened".
    test "the trailing type gets nothing when the leading type exhausts the budget, but gets its turn when it leads" do
      for _ <- 1..10, do: eligible_movie()
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      put_upgrades_config(sweep_enabled: true, sweep_batch_size: 3)

      assert {:ok, %{searches: 3}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "movies"}})

      assert length(movie_search_jobs()) == 3
      assert tv_show_search_jobs() == []

      assert {:ok, %{searches: episode_lead_searches}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      assert episode_lead_searches > 0
      assert tv_show_search_jobs() != []
    end

    test "derives a lead deterministically when no lead arg is given" do
      eligible_movie()

      assert {:ok, %{searches: 1}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    end
  end
end
