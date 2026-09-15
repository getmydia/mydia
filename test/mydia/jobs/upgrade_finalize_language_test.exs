defmodule Mydia.Jobs.UpgradeFinalizeLanguageTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Blacklists
  alias Mydia.Events
  alias Mydia.Jobs.UpgradeFinalize
  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Metadata.Structs.MediaMetadata

  setup do
    original = Application.get_env(:mydia, :runtime_config)
    defaults = Mydia.Config.Schema.defaults()

    Application.put_env(:mydia, :runtime_config, %{
      defaults
      | downloads: %{defaults.downloads | audio_language: "original"}
    })

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    :ok
  end

  defp file_metadata(languages, extra \\ %{}) do
    streams =
      languages
      |> Enum.with_index(1)
      |> Enum.map(fn {language, index} ->
        %StreamInfo{index: index, type: :audio, language: language}
      end)

    %FileMetadata{streams: streams, extra: extra}
  end

  # An old and a new episode file of "Kaiju Garden", whose original language
  # is Japanese. Resolution drives the quality side ("720p" scores well below
  # "4K" under this profile); the audio lists drive the language side.
  defp language_pair(opts) do
    profile =
      quality_profile_fixture(%{
        name: "Finalize language #{System.unique_integer([:positive])}",
        upgrades_allowed: Keyword.get(opts, :upgrades_allowed, true),
        upgrade_until_score: 100,
        min_upgrade_margin: 5,
        quality_standards: %{
          preferred_resolutions: ["2160p", "1080p"],
          preferred_video_codecs: ["h265", "h264"],
          preferred_audio_codecs: ["eac3", "aac"],
          preferred_sources: ["BluRay", "WEB-DL"]
        }
      })

    show =
      insert(:tv_show,
        title: "Kaiju Garden",
        monitored: true,
        quality_profile: profile,
        download_audio_language: Keyword.get(opts, :override),
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :metadata_relay,
          media_type: :tv_show,
          original_language: "ja"
        }
      )

    episode = insert(:episode, media_item: show, monitored: true)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old =
      insert(:media_file,
        episode: episode,
        resolution: Keyword.fetch!(opts, :old_resolution),
        codec: "h264",
        audio_codec: "ac3",
        size: 4 * 1024 * 1024 * 1024,
        analyzed_at: now,
        metadata: file_metadata(Keyword.fetch!(opts, :old_audio))
      )

    download =
      insert(:download,
        media_item: nil,
        episode: episode,
        title: Keyword.get(opts, :release_title, "Kaiju.Garden.S01E01.WEB-DL.x264-GRP"),
        indexer: "test-indexer",
        metadata:
          Map.merge(
            %{"guid" => "guid-#{System.unique_integer([:positive])}"},
            Keyword.get(opts, :download_metadata, %{})
          )
      )

    new =
      insert(:media_file,
        episode: episode,
        resolution: Keyword.fetch!(opts, :new_resolution),
        codec: "h264",
        audio_codec: "ac3",
        size: 4 * 1024 * 1024 * 1024,
        analyzed_at: now,
        supersedes_media_file_id: old.id,
        metadata:
          file_metadata(Keyword.fetch!(opts, :new_audio), %{
            "imported_from_download_id" => download.id
          })
      )

    {old, new, download}
  end

  defp finalize(new), do: UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

  defp event(type, new) do
    [event] =
      Events.list_events(type: type, resource_type: "episode", resource_id: new.episode_id)

    event
  end

  test "a new file in the show's language replaces the old one even when it scores lower" do
    {old, new, _download} =
      language_pair(
        override: "en",
        old_resolution: "4K",
        old_audio: ["jpn"],
        new_resolution: "720p",
        new_audio: ["eng", "jpn"]
      )

    assert {:ok, :upgraded} = finalize(new)
    assert Repo.reload!(old).trashed_at
    refute Repo.reload!(new).trashed_at

    metadata = event("media_file.upgraded", new).metadata
    assert metadata["reason"] == "language"
    assert metadata["old_audio_languages"] == ["ja"]
    assert metadata["new_audio_languages"] == ["en", "ja"]
  end

  test "a new file that lost every preferred language is rejected even when it scores higher" do
    {old, new, download} =
      language_pair(
        old_resolution: "720p",
        old_audio: ["jpn"],
        new_resolution: "4K",
        new_audio: ["ita"]
      )

    assert {:ok, :rejected} = finalize(new)
    refute Repo.reload!(old).trashed_at
    assert Repo.reload!(new).trashed_at
    assert Blacklists.blacklisted?("test-indexer", download.metadata["guid"])
    assert event("media_file.upgrade_rejected", new).metadata["reason"] == "language"
  end

  test "an equal language rank falls back to the quality margin" do
    {old, new, _download} =
      language_pair(
        old_resolution: "720p",
        old_audio: ["jpn"],
        new_resolution: "4K",
        new_audio: ["jpn"]
      )

    assert {:ok, :upgraded} = finalize(new)
    assert Repo.reload!(old).trashed_at
    assert event("media_file.upgraded", new).metadata["reason"] == "quality"
  end

  test "an equal language rank is rejected once the profile no longer allows upgrades" do
    {old, new, _download} =
      language_pair(
        upgrades_allowed: false,
        old_resolution: "720p",
        old_audio: ["jpn"],
        new_resolution: "4K",
        new_audio: ["jpn"]
      )

    assert {:ok, :rejected} = finalize(new)
    refute Repo.reload!(old).trashed_at
    assert event("media_file.upgrade_rejected", new).metadata["reason"] == "quality"
  end

  test "a new file with untagged audio is judged by its release title" do
    {old, new, _download} =
      language_pair(
        override: "en",
        old_resolution: "4K",
        old_audio: ["jpn"],
        new_resolution: "720p",
        new_audio: [nil],
        release_title: "Kaiju.Garden.S01E01.720p.WEB-DL.English.Dub-GRP"
      )

    assert {:ok, :upgraded} = finalize(new)
    assert Repo.reload!(old).trashed_at
    event = event("media_file.upgraded", new)
    assert event.metadata["new_audio_languages"] == ["en"]
    assert event.metadata["reason"] == "language"
  end

  # The fixture's default release title ("Kaiju.Garden.S01E01.WEB-DL.x264-GRP")
  # names no audio token, so ReleaseLanguages.detect/2 falls back to
  # `assumed?: true` and guesses the original language, "ja". These three
  # cover the guess-discounting ruling: a guess counts in the new file's
  # favour only when the old file carries none of the policy's languages, and
  # never gets to reject or blacklist a file on its own.
  test "a guessed title never rejects a new file" do
    {old, new, _download} =
      language_pair(
        override: "en",
        old_resolution: "720p",
        old_audio: ["eng"],
        new_resolution: "4K",
        new_audio: [nil]
      )

    assert {:ok, :upgraded} = finalize(new)
    assert Repo.reload!(old).trashed_at
    assert event("media_file.upgraded", new).metadata["reason"] == "quality"
  end

  test "a guessed title does not skip the margin over a file with a preferred language" do
    {old, new, _download} =
      language_pair(
        old_resolution: "4K",
        old_audio: ["eng"],
        new_resolution: "720p",
        new_audio: [nil]
      )

    assert {:ok, :rejected} = finalize(new)
    refute Repo.reload!(old).trashed_at
    assert event("media_file.upgrade_rejected", new).metadata["reason"] == "quality"
  end

  test "a guessed title still replaces a file with none of the preferred languages" do
    {old, new, _download} =
      language_pair(
        old_resolution: "4K",
        old_audio: ["rus"],
        new_resolution: "720p",
        new_audio: [nil]
      )

    assert {:ok, :upgraded} = finalize(new)
    assert Repo.reload!(old).trashed_at
    assert event("media_file.upgraded", new).metadata["reason"] == "language"
  end

  test "a language rejection from a season pack does not blacklist the pack" do
    {_old, new, download} =
      language_pair(
        old_resolution: "720p",
        old_audio: ["jpn"],
        new_resolution: "4K",
        new_audio: ["ita"],
        download_metadata: %{"season_pack" => true, "season_number" => 1}
      )

    assert {:ok, :rejected} = finalize(new)
    refute Blacklists.blacklisted?("test-indexer", download.metadata["guid"])
  end
end
