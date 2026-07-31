defmodule Mydia.Jobs.UpgradeFinalizeTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Blacklists
  alias Mydia.Events
  alias Mydia.Jobs.UpgradeFinalize

  # Builds a below-cutoff episode file (`old`) and a candidate replacement
  # (`new`) that points `supersedes_media_file_id` at it, both already
  # analyzed (the trigger this job models — Mydia.Library.apply_analysis/2
  # — only fires once analysis has landed). Only `resolution` differs
  # between the two; codec/audio/size are held identical so the score delta
  # is driven purely by the resolution swap the test cares about.
  #
  # The profile is set on the show (episode.media_item), not the media
  # file: QualityProfileResolver.resolve/1 reads media_item.quality_profile,
  # a gotcha that has bitten every prior task touching this feature.
  #
  # `new` also carries a real `imported_from_download_id` pointing at a
  # `Download` row with an `indexer` and `metadata["guid"]` — the exact
  # shape `Mydia.Jobs.MediaImport` writes for every import — so the
  # rejection branch has a real release to blacklist.
  defp upgrade_pair(opts) do
    old_resolution = Keyword.fetch!(opts, :old_resolution)
    new_resolution = Keyword.fetch!(opts, :new_resolution)

    profile =
      quality_profile_fixture(%{
        name: "Upgrade Finalize #{System.unique_integer([:positive])}",
        upgrades_allowed: true,
        upgrade_until_score: 100,
        min_upgrade_margin: 5,
        quality_standards: %{
          preferred_resolutions: ["2160p", "1080p"],
          preferred_video_codecs: ["h265", "h264"],
          preferred_audio_codecs: ["eac3", "aac"],
          preferred_sources: ["BluRay", "WEB-DL"]
        }
      })

    show = insert(:tv_show, monitored: true, quality_profile: profile)
    episode = insert(:episode, media_item: show, monitored: true)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    old =
      insert(:media_file,
        episode: episode,
        resolution: old_resolution,
        codec: "H.264 (High)",
        audio_codec: "DD+ 5.1",
        size: 4 * 1024 * 1024 * 1024,
        analyzed_at: now,
        trashed_at: nil
      )

    download =
      insert(:download,
        media_item: nil,
        episode: episode,
        title: "Episode.Release.#{System.unique_integer([:positive])}",
        indexer: "test-indexer",
        metadata: %{"guid" => "guid-#{System.unique_integer([:positive])}"}
      )

    new =
      insert(:media_file,
        episode: episode,
        resolution: new_resolution,
        codec: "H.264 (High)",
        audio_codec: "DD+ 5.1",
        size: 4 * 1024 * 1024 * 1024,
        analyzed_at: now,
        supersedes_media_file_id: old.id,
        metadata: %{imported_from_download_id: download.id}
      )

    {old, new, download}
  end

  test "trashes the superseded file when the new file is genuinely better" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    assert {:ok, :upgraded} =
             UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    # Both sides asserted explicitly: getting the direction backwards (new
    # trashed, old kept) would be the worst possible failure mode here.
    assert Repo.reload!(old).trashed_at
    refute Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil

    # The activity trail (review finding 2): create_event_async runs
    # synchronously under the sandbox (Events.create_event_async/1), so the
    # event is already committed by the time perform/1 returns.
    assert [event] =
             Events.list_events(
               type: "media_file.upgraded",
               resource_type: "episode",
               resource_id: new.episode_id
             )

    assert event.metadata["old_score"]
    assert event.metadata["new_score"]
    assert event.metadata["breakdown_delta"] != %{}
  end

  test "trashes the new file and keeps the old one when the release lied" do
    {old, new, download} = upgrade_pair(old_resolution: "4K", new_resolution: "720p")

    assert {:ok, :rejected} =
             UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    # Both sides asserted explicitly, same reasoning as above but mirrored.
    refute Repo.reload!(old).trashed_at
    assert Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil

    guid = download.metadata["guid"]
    assert Blacklists.blacklisted?("test-indexer", guid)

    # The activity trail (review finding 2).
    assert [event] =
             Events.list_events(
               type: "media_file.upgrade_rejected",
               resource_type: "episode",
               resource_id: new.episode_id
             )

    assert event.metadata["old_score"]
    assert event.metadata["new_score"]
    assert event.metadata["breakdown_delta"] != %{}
  end

  # Task 10 review finding 1 (CRITICAL): the new file can be trashed by
  # something else — an operator action, a re-scan, a cleanup — in the
  # window between analysis landing and this job running on the :media
  # queue, or by a prior partially-failed run of THIS job (trash succeeded,
  # clear_pointer did not, Oban retries). Without a guard, the job would
  # still score the trashed file as a live candidate, potentially take the
  # upgrade branch, and trash the old file too — leaving zero active copies
  # until TrashCleanup permanently deletes both after the retention window.
  test "never trashes the old file when the new file was already trashed by something else" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    {:ok, _} =
      new
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    assert {:ok, :noop} = UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    # The critical assertion: a trashed new file must never cause the old
    # file to be trashed too.
    refute Repo.reload!(old).trashed_at
    assert Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil
  end

  # Task 10 review finding 3: a permanently unscorable comparison (deleted
  # quality profile, or one blanked to no quality standards, or a file
  # attached to neither an episode nor a media item) used to strand the
  # pointer forever and leave both files silently active. It must now clear
  # the pointer, return a terminal outcome, and record an operator-visible
  # event rather than relying on Oban exhausting retries.
  test "clears the pointer and returns :unscorable when no quality profile can be resolved, leaving both files untouched" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    # Strip the profile from the show so QualityProfileResolver.resolve/1
    # falls through to Settings.get_default_quality_profile/0, which is nil
    # in a fresh test DB with no default configured — simulating a deleted
    # quality profile.
    episode = Repo.get!(Mydia.Media.Episode, new.episode_id) |> Repo.preload(:media_item)

    {:ok, _} =
      episode.media_item
      |> Ecto.Changeset.change(quality_profile_id: nil)
      |> Repo.update()

    assert {:ok, :unscorable} =
             UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    # Neither file is touched — the whole point of the fix: without it, the
    # pointer would strand forever with both files silently active.
    refute Repo.reload!(old).trashed_at
    refute Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil

    assert [event] =
             Events.list_events(
               type: "job.failed",
               actor_type: :job,
               actor_id: "upgrade_finalize"
             )

    assert event.metadata["media_file_id"] == new.id
  end

  test "is a no-op when the superseded file was hard-deleted, because the FK cascade already cleared the pointer" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    # media_files.supersedes_media_file_id is `on_delete: :nilify_all` (see
    # priv/repo/migrations/20260730170000_add_quality_upgrade_fields.exs), so
    # a hard delete of `old` nilifies `new.supersedes_media_file_id` in the
    # same transaction, before this job ever runs. By the time perform/1
    # reads `new` fresh from the DB, the pointer is already nil — this lands
    # on the same {:ok, :noop} branch as an already-finalized file, not
    # :orphaned. See the "already trashed" test below for the outcome that
    # actually exercises the orphaned branch: the realistic "gone" case in
    # this codebase is a soft trash, not a hard delete (see CLAUDE.md: never
    # call a hard delete from this feature).
    Repo.delete!(old)

    assert {:ok, :noop} = UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})
    refute Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil
  end

  test "keeps the new file as an ordinary import when the old one is already trashed" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    {:ok, _} =
      old
      |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    assert {:ok, :orphaned} =
             UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    refute Repo.reload!(new).trashed_at
    assert Repo.reload!(new).supersedes_media_file_id == nil
  end

  test "is a no-op when the pointer has already been cleared" do
    {old, new, _download} = upgrade_pair(old_resolution: "720p", new_resolution: "4K")

    assert {:ok, :upgraded} =
             UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    assert {:ok, :noop} = UpgradeFinalize.perform(%Oban.Job{args: %{"media_file_id" => new.id}})

    # Re-running must not touch either file a second time.
    assert Repo.reload!(old).trashed_at
    refute Repo.reload!(new).trashed_at
  end
end
