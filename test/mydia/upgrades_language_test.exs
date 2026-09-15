defmodule Mydia.UpgradesLanguageTest do
  use Mydia.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Search
  alias Mydia.Search.SearchBackoff
  alias Mydia.Upgrades

  setup do
    original = Application.get_env(:mydia, :runtime_config)
    defaults = Mydia.Config.Schema.defaults()

    Application.put_env(:mydia, :runtime_config, %{
      defaults
      | streaming: %{defaults.streaming | audio_language: ["original", "en"]}
    })

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  # upgrades_allowed: false on purpose. Language eligibility must not depend on
  # the quality upgrade switch or the cutoff.
  defp profile do
    quality_profile_fixture(%{
      name: "Language #{System.unique_integer([:positive])}",
      upgrades_allowed: false,
      quality_standards: %{preferred_resolutions: ["1080p"]}
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

  defp audio(languages) do
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

  defp movie_with_audio(languages) do
    movie =
      insert(:media_item,
        type: "movie",
        title: "Paper Lantern Club",
        monitored: true,
        quality_profile: profile(),
        metadata: metadata(:movie)
      )

    file =
      insert(:media_file,
        media_item: movie,
        episode: nil,
        resolution: "1080p",
        codec: "h264",
        metadata: audio(languages),
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: now()
      )

    {movie, file}
  end

  defp show_with(attrs \\ []) do
    insert(
      :tv_show,
      Keyword.merge(
        [
          title: "Kaiju Garden",
          monitored: true,
          quality_profile: profile(),
          metadata: metadata(:tv_show)
        ],
        attrs
      )
    )
  end

  defp episode_with_audio(show, number, languages) do
    episode =
      insert(:episode,
        media_item: show,
        season_number: 1,
        episode_number: number,
        monitored: true
      )

    file =
      insert(:media_file,
        episode: episode,
        resolution: "1080p",
        codec: "h264",
        metadata: audio(languages),
        size: 2 * 1024 * 1024 * 1024,
        analyzed_at: now()
      )

    {episode, file}
  end

  defp movie_ids(candidates), do: candidates |> Enum.map(& &1.media_item.id) |> Enum.sort()

  defp age_backoff(resource_id, days) do
    past = DateTime.add(now(), -days * 86_400, :second)

    Repo.update_all(from(b in SearchBackoff, where: b.resource_id == ^resource_id),
      set: [first_failed_at: past, next_eligible_at: past]
    )
  end

  describe "language_eligible_movies/2" do
    test "flags a movie carrying none of the server languages, even with upgrades off" do
      {italian, file} = movie_with_audio(["ita"])
      {_japanese, _} = movie_with_audio(["jpn"])
      {_english, _} = movie_with_audio(["eng"])

      assert [candidate] = Upgrades.language_eligible_movies(10)
      assert candidate.media_item.id == italian.id
      assert candidate.media_file.id == file.id
      assert candidate.reasons == [:language]
    end

    test "never flags a movie whose audio is untagged" do
      movie_with_audio([nil])
      assert Upgrades.language_eligible_movies(10) == []
    end

    test "stamps scanned movies without a gap and leaves candidates for the sweep" do
      {gap, _} = movie_with_audio(["ita"])
      {clean, _} = movie_with_audio(["jpn"])

      Upgrades.language_eligible_movies(10)

      assert Repo.reload!(clean).last_language_check_at
      refute Repo.reload!(gap).last_language_check_at
    end

    test "a language backoff suppresses the movie and a quality backoff does not" do
      {movie, _} = movie_with_audio(["ita"])

      {:ok, _} = Search.record_failure("movie_upgrade", movie.id, "no_results")
      assert movie_ids(Upgrades.language_eligible_movies(10)) == [movie.id]

      {:ok, _} = Search.record_failure("movie_language_upgrade", movie.id, "no_results")
      assert Upgrades.language_eligible_movies(10) == []
    end

    test "gives up once the first language failure is 90 days old" do
      {stale, _} = movie_with_audio(["ita"])
      {recent, _} = movie_with_audio(["ita"])

      for movie <- [stale, recent] do
        {:ok, _} = Search.record_failure("movie_language_upgrade", movie.id, "no_results")
      end

      age_backoff(stale.id, 91)
      age_backoff(recent.id, 10)

      assert movie_ids(Upgrades.language_eligible_movies(10)) == [recent.id]
      refute Upgrades.bucket_open?(:movie, :language, stale.id)
      assert Upgrades.bucket_open?(:movie, :language, recent.id)
      assert Upgrades.bucket_open?(:movie, :quality, stale.id)
    end

    test "scopes the scan to one item" do
      {target, _} = movie_with_audio(["ita"])
      {_other, _} = movie_with_audio(["ita"])

      assert movie_ids(Upgrades.language_eligible_movies(10, media_item_id: target.id)) == [
               target.id
             ]
    end
  end

  describe "language_eligible_episodes/2" do
    test "a show override flags every episode without its first language" do
      show = show_with(audio_languages: ["en"])
      {missing, _} = episode_with_audio(show, 1, ["jpn"])
      {_dual, _} = episode_with_audio(show, 2, ["jpn", "eng"])

      assert [%{episode: found, reasons: [:language]}] = Upgrades.language_eligible_episodes(10)
      assert found.id == missing.id
    end

    test "the server default leaves an English episode of a Japanese show alone" do
      show = show_with()
      {_english, _} = episode_with_audio(show, 1, ["eng"])
      {russian, _} = episode_with_audio(show, 2, ["rus"])

      assert [%{episode: found}] = Upgrades.language_eligible_episodes(10)
      assert found.id == russian.id
    end
  end

  describe "merge_candidates/3" do
    test "interleaves the two lists and unions the reasons of a shared entry" do
      quality = [%{id: "q1"}, %{id: "both"}, %{id: "q2"}]
      language = [%{id: "l1", reasons: [:language]}, %{id: "both", reasons: [:language]}]

      merged = Upgrades.merge_candidates(quality, language, & &1.id)

      assert Enum.map(merged, & &1.id) == ["q1", "l1", "both", "q2"]
      assert Enum.find(merged, &(&1.id == "both")).reasons == [:quality, :language]
      assert Enum.find(merged, &(&1.id == "q1")).reasons == [:quality]
    end
  end
end
