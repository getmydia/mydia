defmodule Mydia.Jobs.UpgradeSweepLanguageTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.UpgradeSweep
  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Streaming.Codec

  setup do
    original = Application.get_env(:mydia, :runtime_config)
    put_config(10)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  defp put_config(batch_size) do
    defaults = Mydia.Config.Schema.defaults()

    Application.put_env(:mydia, :runtime_config, %{
      defaults
      | upgrades: struct(defaults.upgrades, sweep_enabled: true, sweep_batch_size: batch_size),
        downloads: %{defaults.downloads | audio_language: "original"}
    })
  end

  defp profile(upgrades_allowed) do
    quality_profile_fixture(%{
      name: "Sweep language #{System.unique_integer([:positive])}",
      upgrades_allowed: upgrades_allowed,
      upgrade_until_score: 100,
      quality_standards: %{preferred_resolutions: ["2160p"]}
    })
  end

  defp metadata(media_type) do
    %MediaMetadata{
      provider_id: "1",
      provider: :metadata_relay,
      media_type: media_type,
      original_language: "ja"
    }
  end

  # nil languages means a file whose streams were never captured.
  defp file_metadata(nil), do: nil

  defp file_metadata(languages) do
    %FileMetadata{
      streams:
        languages
        |> Enum.with_index(1)
        |> Enum.map(fn {language, index} ->
          %StreamInfo{index: index, type: :audio, language: language}
        end)
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp movie(languages, upgrades_allowed) do
    movie =
      insert(:media_item,
        type: "movie",
        title: "Paper Lantern Club",
        monitored: true,
        quality_profile: profile(upgrades_allowed),
        metadata: metadata(:movie)
      )

    insert(:media_file,
      media_item: movie,
      episode: nil,
      resolution: "720p",
      codec: "h264",
      metadata: file_metadata(languages),
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: now()
    )

    movie
  end

  defp show_with_episodes(override, gap_count, total) do
    show =
      insert(:tv_show,
        title: "Kaiju Garden",
        monitored: true,
        download_audio_language: override,
        quality_profile: profile(false),
        metadata: metadata(:tv_show)
      )

    for number <- 1..total do
      languages = if number <= gap_count, do: ["jpn"], else: ["eng"]

      episode =
        insert(:episode,
          media_item: show,
          season_number: 1,
          episode_number: number,
          monitored: true
        )

      insert(:media_file,
        episode: episode,
        resolution: "1080p",
        codec: "h264",
        metadata: file_metadata(languages),
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: now()
      )
    end

    show
  end

  # A profile whose cutoff separates the two fixtures below: 720p + "AAC
  # Stereo" scores 75.5 (below the 90 cutoff), 2160p + "AAC 5.1" + a Dolby
  # Vision-over-HDR10 layer scores 94.0 (above it). See
  # test/mydia/jobs/upgrade_sweep_test.exs's below_cutoff_episode/1 and
  # above_cutoff_episode/1 for the derivation; this mirrors both shapes so
  # the same scores apply.
  defp scoring_profile do
    quality_profile_fixture(%{
      name: "Sweep mixed #{System.unique_integer([:positive])}",
      upgrades_allowed: true,
      upgrade_until_score: 90,
      quality_standards: %{
        preferred_resolutions: ["2160p"],
        preferred_audio_channels: ["5.1"]
      }
    })
  end

  # Below cutoff (quality candidate), audio in the show's chosen language so
  # it carries no language gap.
  defp quality_only_episode(show, profile, season_number, episode_number) do
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
      codec: "h264",
      audio_codec: Codec.normalize_audio_codec("AAC Stereo"),
      metadata: %FileMetadata{
        audio_codec_raw: "AAC Stereo",
        streams: [%StreamInfo{index: 1, type: :audio, language: "eng"}]
      },
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: now(),
      quality_profile: profile
    )

    episode
  end

  # Above cutoff (not a quality candidate), audio missing the show's chosen
  # language so it carries a language gap.
  defp language_only_episode(show, profile, season_number, episode_number) do
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
      metadata: %FileMetadata{
        audio_codec_raw: "AAC 5.1",
        streams: [%StreamInfo{index: 1, type: :audio, language: "jpn"}]
      },
      hdr_format: :hdr10,
      dolby_vision_profile: 8,
      dolby_vision_bl_compat_id: 1,
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: now(),
      quality_profile: profile
    )

    episode
  end

  defp jobs(worker), do: Enum.filter(Repo.all(Oban.Job), &(&1.worker == worker))

  test "a movie missing its language is searched for language even with upgrades off" do
    movie = movie(["ita"], false)

    assert {:ok, %{searches: 1}} = UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "movies"}})

    assert [job] = jobs("Mydia.Jobs.MovieSearch")
    assert job.args["media_item_id"] == movie.id
    assert job.args["reasons"] == ["language"]
    assert Repo.reload!(movie).last_language_check_at
    refute Repo.reload!(movie).last_upgrade_check_at
  end

  test "a movie short on both quality and language costs one search carrying both reasons" do
    movie = movie(["ita"], true)

    assert {:ok, %{searches: 1}} = UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "movies"}})

    assert [job] = jobs("Mydia.Jobs.MovieSearch")
    assert job.args["reasons"] == ["quality", "language"]
    assert Repo.reload!(movie).last_language_check_at
    assert Repo.reload!(movie).last_upgrade_check_at
  end

  test "language candidates share the budget instead of queueing behind quality" do
    for _ <- 1..3, do: movie(nil, true)
    for _ <- 1..3, do: movie(["ita"], false)
    put_config(2)

    assert {:ok, %{searches: 2}} = UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "movies"}})

    reasons = "Mydia.Jobs.MovieSearch" |> jobs() |> Enum.map(& &1.args["reasons"]) |> Enum.sort()
    assert reasons == [["language"], ["quality"]]
  end

  test "a season of episodes missing the show's language becomes one pack search" do
    show = show_with_episodes("en", 8, 10)

    assert {:ok, %{searches: 1}} =
             UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

    assert [job] = jobs("Mydia.Jobs.TVShowSearch")
    assert job.args["mode"] == "upgrade_season"
    assert job.args["media_item_id"] == show.id
    assert job.args["reasons"] == ["language"]
  end

  test "a season backing off in the language bucket falls back to episode searches" do
    show = show_with_episodes("en", 8, 10)

    {:ok, _} =
      Mydia.Search.record_failure("season_language_upgrade", show.id, "all_filtered",
        season_number: 1
      )

    assert {:ok, %{searches: 8}} =
             UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

    episode_jobs = jobs("Mydia.Jobs.TVShowSearch")
    assert length(episode_jobs) == 8
    assert Enum.all?(episode_jobs, &(&1.args["mode"] == "upgrade_episode"))
    assert Enum.all?(episode_jobs, &(&1.args["reasons"] == ["language"]))
  end

  test "a pack search dropping the backed-off language reason stamps only what it searched" do
    profile = scoring_profile()

    show =
      insert(:tv_show,
        title: "Kaiju Garden",
        monitored: true,
        download_audio_language: "en",
        quality_profile: profile,
        metadata: metadata(:tv_show)
      )

    quality_only = for n <- 1..4, do: quality_only_episode(show, profile, 1, n)
    language_only = for n <- 5..8, do: language_only_episode(show, profile, 1, n)

    {:ok, _backoff} =
      Mydia.Search.record_failure("season_language_upgrade", show.id, "all_filtered",
        season_number: 1
      )

    assert {:ok, %{searches: 1}} =
             UpgradeSweep.perform(%Oban.Job{args: %{"lead" => "episodes"}})

    assert [job] = jobs("Mydia.Jobs.TVShowSearch")
    assert job.args["mode"] == "upgrade_season"
    assert job.args["media_item_id"] == show.id
    assert job.args["reasons"] == ["quality"]

    assert Enum.all?(quality_only, fn ep -> Repo.reload!(ep).last_upgrade_check_at end)
    refute Enum.any?(language_only, fn ep -> Repo.reload!(ep).last_language_check_at end)
  end

  test "a scoped sweep searches only that item, for language only" do
    target = movie(["ita"], true)
    _other_gap = movie(["ita"], false)
    _quality_only = movie(nil, true)

    assert {:ok, %{searches: 1}} =
             UpgradeSweep.perform(%Oban.Job{args: %{"media_item_id" => target.id}})

    assert [job] = jobs("Mydia.Jobs.MovieSearch")
    assert job.args["media_item_id"] == target.id
    assert job.args["reasons"] == ["language"]
  end

  test "enqueue_for_item/1 inserts a sweep scoped to the item" do
    movie = movie(["ita"], false)

    assert :ok = UpgradeSweep.enqueue_for_item(movie.id)

    assert [job] = jobs("Mydia.Jobs.UpgradeSweep")
    assert job.args == %{"media_item_id" => movie.id}
  end
end
