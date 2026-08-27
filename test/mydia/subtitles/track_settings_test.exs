defmodule Mydia.Subtitles.TrackSettingsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Subtitles.TrackSettings

  import Mydia.MediaFixtures

  setup do
    %{media_file: media_file_fixture()}
  end

  describe "offset_ms/2" do
    test "returns zero for a track with no stored setting", %{media_file: media_file} do
      assert TrackSettings.offset_ms(media_file.id, "3") == 0
    end

    test "returns the stored offset", %{media_file: media_file} do
      {:ok, _} = TrackSettings.set_offset(media_file.id, "3", 1_250)

      assert TrackSettings.offset_ms(media_file.id, "3") == 1_250
    end

    test "returns zero for an unparseable media file id" do
      assert TrackSettings.offset_ms("not-a-uuid", "3") == 0
    end
  end

  describe "set_offset/3" do
    test "updates rather than duplicating on a second call", %{media_file: media_file} do
      {:ok, first} = TrackSettings.set_offset(media_file.id, "3", 500)
      {:ok, second} = TrackSettings.set_offset(media_file.id, "3", -750)

      assert first.id == second.id
      assert TrackSettings.offset_ms(media_file.id, "3") == -750
    end

    test "rejects an out-of-range offset", %{media_file: media_file} do
      assert {:error, changeset} = TrackSettings.set_offset(media_file.id, "3", 900_000)
      assert %{offset_ms: [_ | _]} = errors_on(changeset)
    end

    test "returns a changeset error rather than raising for an unparseable media file id" do
      assert {:error, changeset} = TrackSettings.set_offset("not-a-uuid", "3", 500)
      assert %{media_file_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "offsets_for_media_file/1" do
    test "returns a map keyed by track_ref", %{media_file: media_file} do
      {:ok, _} = TrackSettings.set_offset(media_file.id, "3", 100)
      {:ok, _} = TrackSettings.set_offset(media_file.id, "4", -200)

      assert TrackSettings.offsets_for_media_file(media_file.id) == %{"3" => 100, "4" => -200}
    end

    test "returns an empty map when nothing is stored", %{media_file: media_file} do
      assert TrackSettings.offsets_for_media_file(media_file.id) == %{}
    end

    test "returns an empty map for an unparseable media file id" do
      assert TrackSettings.offsets_for_media_file("not-a-uuid") == %{}
    end
  end

  describe "delete_for_track/2" do
    test "removes the row", %{media_file: media_file} do
      {:ok, _} = TrackSettings.set_offset(media_file.id, "3", 100)

      assert :ok = TrackSettings.delete_for_track(media_file.id, "3")
      assert TrackSettings.offset_ms(media_file.id, "3") == 0
    end

    test "is idempotent when nothing is stored", %{media_file: media_file} do
      assert :ok = TrackSettings.delete_for_track(media_file.id, "9")
    end

    test "is a no-op for an unparseable media file id" do
      assert :ok = TrackSettings.delete_for_track("not-a-uuid", "3")
    end
  end
end
