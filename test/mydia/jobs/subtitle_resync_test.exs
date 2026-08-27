defmodule Mydia.Jobs.SubtitleResyncTest do
  use Mydia.DataCase, async: true

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures

  alias Mydia.Jobs.SubtitleResync

  describe "new/1" do
    test "builds a job on the subsync queue" do
      changeset = SubtitleResync.new(%{media_file_id: Ecto.UUID.generate(), track_ref: "3"})

      assert changeset.changes.queue == "subsync"
      assert changeset.changes.worker == "Mydia.Jobs.SubtitleResync"
    end

    test "carries the media file and track through args" do
      id = Ecto.UUID.generate()
      changeset = SubtitleResync.new(%{media_file_id: id, track_ref: "3"})

      assert changeset.changes.args == %{media_file_id: id, track_ref: "3"}
    end
  end

  describe "perform/1" do
    test "succeeds when the media file no longer exists" do
      job = %Oban.Job{
        args: %{"media_file_id" => Ecto.UUID.generate(), "track_ref" => "3"}
      }

      assert :ok = SubtitleResync.perform(job)
    end

    test "succeeds when the media file id is not a well-formed UUID" do
      # Pins the contract: perform/1 returns :ok for a malformed id rather
      # than crashing. On PostgreSQL, Repo.get/2 raises Ecto.Query.CastError
      # binding a non-UUID string, which this guard heads off before the
      # query ever runs; this worktree's default SQLite adapter tolerates
      # the same string and would return nil either way (see
      # Mydia.Subtitles.TrackSettings's moduledoc for the adapter split), so
      # this test cannot demonstrate the crash locally, only the intended
      # behavior. Nothing enqueues a malformed id today, but a phx-value on a
      # client-facing control is forgeable (Task 8).
      job = %Oban.Job{
        args: %{"media_file_id" => "not-a-uuid", "track_ref" => "3"}
      }

      assert :ok = SubtitleResync.perform(job)
    end

    # Regression guard for the bug the coordinator caught: Library.get_media_file/1
    # without `preload: [:library_path]` leaves the association as
    # `%Ecto.Association.NotLoaded{}`, which MediaFile.absolute_path/1 logs a
    # warning about and returns nil for, so Resync.run/2 falls back to a bare
    # relative_path that ffmpeg cannot open. Every real media file would
    # silently fail to re-sync. This does not need a real audio file on disk
    # (or even ffmpeg installed) to prove the preload happened: it only needs
    # to show that the unloaded-association code path was never reached.
    test "preloads library_path so a real media file is not left with an unloaded association" do
      media_file = media_file_fixture()

      job = %Oban.Job{
        args: %{"media_file_id" => media_file.id, "track_ref" => "3"}
      }

      log =
        capture_log(fn ->
          assert :ok = SubtitleResync.perform(job)
        end)

      refute log =~ "unloaded library_path association"
    end
  end
end
