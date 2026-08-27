defmodule Mydia.Jobs.SubtitleResyncTest do
  use Mydia.DataCase, async: true

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
  end
end
