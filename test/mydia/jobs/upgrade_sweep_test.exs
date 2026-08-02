defmodule Mydia.Jobs.UpgradeSweepTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.UpgradeSweep
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Streaming.Codec

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
      codec: "h264",
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
  # upgrade_until_score: 90, so this file is eligible for upgrade. Pass
  # `audio: "AAC 5.1"` to make one fixture distinctly higher-scoring (84.5,
  # still below cutoff) than its siblings, for tests that need a
  # discriminating "best in the season" target. See the task report for the
  # full score derivation. Any other `opts` override the media_file attrs.
  #
  # `audio:` sets both halves of what apply_analysis/2 writes: the
  # streaming-normalized column *and* metadata.audio_codec_raw, which is
  # where the channel layout survives and where Attrs reads it from.
  defp below_cutoff_episode(show, profile, season_number, episode_number, opts \\ []) do
    {audio, opts} = Keyword.pop(opts, :audio, "AAC Stereo")

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
            codec: "h264",
            audio_codec: Codec.normalize_audio_codec(audio),
            metadata: %FileMetadata{audio_codec_raw: audio},
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
      codec: "h264",
      audio_codec: Codec.normalize_audio_codec("AAC 5.1"),
      metadata: %FileMetadata{audio_codec_raw: "AAC 5.1"},
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
      # The boosted fixture sits at a middle episode number (4 of 8), not
      # first or last, so neither hd/1 nor List.last/1 could coincidentally
      # satisfy the max_by assertion below via insertion/DB row order.
      for n <- 1..3, do: below_cutoff_episode(show, profile, 1, n)
      {_episode, best_file} = below_cutoff_episode(show, profile, 1, 4, audio: "AAC 5.1")
      for n <- 5..8, do: below_cutoff_episode(show, profile, 1, n)
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
      {ep2, file2} = below_cutoff_episode(show, profile, 1, 2, audio: "AAC 5.1")
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

    # A season pack search that keeps finding no qualifying pack backs off
    # in TVShowSearch's "season_upgrade" bucket. Without this suppression,
    # the sweep would re-enqueue the same season-pack search on every run
    # that reaches it - the same unbounded indexer cost the "never fall
    # back" rule inside TVShowSearch.search_season_upgrade/4 exists to
    # prevent, just moved one layer up to the sweep's own routing decision.
    # The group still costs a search - each below-cutoff episode is
    # individually eligible via its own, unrelated "episode_upgrade"
    # bucket - it is only the pack shape that is suppressed.
    test "routes to individual searches when the season pack is in season_upgrade backoff" do
      {show, profile} = show_with_profile()
      for n <- 1..8, do: below_cutoff_episode(show, profile, 1, n)
      for n <- 9..10, do: above_cutoff_episode(show, profile, 1, n)

      {:ok, _backoff} =
        Mydia.Search.record_failure("season_upgrade", show.id, "all_filtered", season_number: 1)

      assert {:ok, %{searches: 8}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      jobs = tv_show_search_jobs()
      assert length(jobs) == 8
      assert Enum.all?(jobs, &(&1.args["mode"] == "upgrade_episode"))
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

    # An over-budget group must be skipped, not abort the whole run: smaller,
    # affordable groups behind it in iteration order still need their turn.
    # Enum.group_by/2 returns a map, and Erlang's small-map representation
    # iterates keys in term order, so {media_item_id, season_number} keys
    # sort primarily by media_item_id — this test assigns the oversized
    # season to whichever show has the lexicographically smaller id, forcing
    # it to be scanned first regardless of random UUID generation, so the
    # scenario this guards against is reliably exercised rather than
    # depending on luck.
    test "an oversized group ordered first is skipped, not a whole-run abort, and stays unstamped" do
      {show_a, profile_a} = show_with_profile()
      {show_b, profile_b} = show_with_profile()

      {oversized_show, oversized_profile, affordable_show, affordable_profile} =
        if show_a.id < show_b.id do
          {show_a, profile_a, show_b, profile_b}
        else
          {show_b, profile_b, show_a, profile_a}
        end

      # 13 of 20 below cutoff = 65% < 70% -> individual mode, cost 13 --
      # more than the whole budget below.
      oversized_episodes =
        for n <- 1..13 do
          {episode, _file} = below_cutoff_episode(oversized_show, oversized_profile, 1, n)
          episode
        end

      for n <- 14..20, do: above_cutoff_episode(oversized_show, oversized_profile, 1, n)

      # 2 of 10 below cutoff = 20% < 70% -> individual mode, cost 2 -- fits
      # comfortably in what's left after the oversized group is skipped.
      {ep1, _file1} = below_cutoff_episode(affordable_show, affordable_profile, 1, 1)
      {ep2, _file2} = below_cutoff_episode(affordable_show, affordable_profile, 1, 2)
      for n <- 3..10, do: above_cutoff_episode(affordable_show, affordable_profile, 1, n)

      put_upgrades_config(sweep_enabled: true, sweep_batch_size: 10)

      assert {:ok, %{searches: 2}} =
               UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

      assert length(tv_show_search_jobs()) == 2

      # The affordable season was searched and stamped...
      assert Repo.reload!(ep1).last_upgrade_check_at
      assert Repo.reload!(ep2).last_upgrade_check_at

      # ...but the oversized season was skipped for budget, never searched,
      # and must stay unstamped so a later run can still pick it up. A run
      # that halted the whole fold instead of skipping would leave this
      # season permanently starved (unaffordable at any budget below its
      # cost, yet marked checked every time).
      refute Enum.any?(oversized_episodes, fn ep -> Repo.reload!(ep).last_upgrade_check_at end)
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
