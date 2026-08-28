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

  describe "resync_states_for_media_file/1" do
    test "returns a map keyed by track_ref, omitting tracks never attempted", %{
      media_file: media_file
    } do
      {:ok, _} = TrackSettings.record_resync(media_file.id, "3", :low_confidence, 0.09)
      {:ok, _} = TrackSettings.record_resync(media_file.id, "4", :ok, 0.95)
      {:ok, _} = TrackSettings.set_offset(media_file.id, "5", 100)

      assert TrackSettings.resync_states_for_media_file(media_file.id) == %{
               "3" => "low_confidence",
               "4" => "ok"
             }
    end

    test "returns an empty map when nothing is stored", %{media_file: media_file} do
      assert TrackSettings.resync_states_for_media_file(media_file.id) == %{}
    end

    test "returns an empty map for an unparseable media file id" do
      assert TrackSettings.resync_states_for_media_file("not-a-uuid") == %{}
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

  describe "record_resync/4" do
    test "stores state and score without touching the offset", %{media_file: media_file} do
      {:ok, _} = TrackSettings.set_offset(media_file.id, "3", 1200)

      assert {:ok, setting} =
               TrackSettings.record_resync(media_file.id, "3", :low_confidence, 0.09)

      assert setting.offset_ms == 1200
      assert setting.resync_state == "low_confidence"
      assert setting.resync_score == 0.09
      assert setting.resync_at != nil
    end

    test "creates a row for a track that has no offset yet", %{media_file: media_file} do
      assert {:ok, setting} = TrackSettings.record_resync(media_file.id, "4", :no_audio, nil)

      assert setting.offset_ms == 0
      assert setting.resync_state == "no_audio"
    end

    test "rejects a state outside the known set", %{media_file: media_file} do
      assert {:error, changeset} =
               TrackSettings.record_resync(media_file.id, "3", :nonsense, 1.0)

      assert "is invalid" in errors_on(changeset).resync_state
    end

    test "accepts too_few_cues as a resync state", %{media_file: media_file} do
      assert {:ok, setting} =
               TrackSettings.record_resync(media_file.id, "3", :too_few_cues, 0.4)

      assert setting.resync_state == "too_few_cues"
    end

    test "returns a changeset error rather than raising for an unparseable media file id" do
      assert {:error, changeset} = TrackSettings.record_resync("not-a-uuid", "3", :ok, 0.9)
      assert %{media_file_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "offsets_for_media_files/1 and resync_states_for_media_files/1" do
    setup do
      media_item = media_item_fixture(%{type: "movie"})
      file_a = media_file_fixture(%{media_item_id: media_item.id})
      file_b = media_file_fixture(%{media_item_id: media_item.id})
      file_c = media_file_fixture(%{media_item_id: media_item.id})

      {:ok, file_a: file_a, file_b: file_b, file_c: file_c}
    end

    test "groups offsets by media file and omits files with no settings", ctx do
      {:ok, _} = TrackSettings.set_offset(ctx.file_a.id, "3", 250)
      {:ok, _} = TrackSettings.set_offset(ctx.file_a.id, "4", -100)
      {:ok, _} = TrackSettings.set_offset(ctx.file_b.id, "3", 500)

      result =
        TrackSettings.offsets_for_media_files([ctx.file_a.id, ctx.file_b.id, ctx.file_c.id])

      assert result[ctx.file_a.id] == %{"3" => 250, "4" => -100}
      assert result[ctx.file_b.id] == %{"3" => 500}
      refute Map.has_key?(result, ctx.file_c.id)
    end

    test "groups resync states and omits tracks with no state", ctx do
      {:ok, _} = TrackSettings.set_offset(ctx.file_a.id, "3", 250)
      {:ok, _} = TrackSettings.record_resync(ctx.file_a.id, "3", :low_confidence, nil)
      {:ok, _} = TrackSettings.set_offset(ctx.file_b.id, "7", 0)

      result =
        TrackSettings.resync_states_for_media_files([ctx.file_a.id, ctx.file_b.id, ctx.file_c.id])

      assert result[ctx.file_a.id] == %{"3" => "low_confidence"}
      refute Map.has_key?(result, ctx.file_b.id)
      refute Map.has_key?(result, ctx.file_c.id)
    end

    test "returns an empty map for an empty id list" do
      assert TrackSettings.offsets_for_media_files([]) == %{}
      assert TrackSettings.resync_states_for_media_files([]) == %{}
    end

    test "tolerates a malformed id the way the per-file functions do", ctx do
      assert TrackSettings.offsets_for_media_files([ctx.file_a.id, "not-a-uuid"]) == %{}
    end
  end
end
