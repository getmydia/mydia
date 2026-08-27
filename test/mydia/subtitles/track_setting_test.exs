defmodule Mydia.Subtitles.TrackSettingTest do
  use Mydia.DataCase, async: true

  alias Mydia.Subtitles.TrackSetting

  import Mydia.MediaFixtures

  describe "changeset/2" do
    test "accepts an offset inside the allowed range" do
      media_file = media_file_fixture()

      changeset =
        TrackSetting.changeset(%TrackSetting{}, %{
          media_file_id: media_file.id,
          track_ref: "3",
          offset_ms: 2_500
        })

      assert changeset.valid?
    end

    test "rejects an offset above the ceiling" do
      media_file = media_file_fixture()

      changeset =
        TrackSetting.changeset(%TrackSetting{}, %{
          media_file_id: media_file.id,
          track_ref: "3",
          offset_ms: 600_001
        })

      refute changeset.valid?
      assert %{offset_ms: [_ | _]} = errors_on(changeset)
    end

    test "rejects an offset below the floor" do
      media_file = media_file_fixture()

      changeset =
        TrackSetting.changeset(%TrackSetting{}, %{
          media_file_id: media_file.id,
          track_ref: "3",
          offset_ms: -600_001
        })

      refute changeset.valid?
    end

    test "requires media_file_id and track_ref" do
      changeset = TrackSetting.changeset(%TrackSetting{}, %{offset_ms: 0})

      refute changeset.valid?
      assert %{media_file_id: [_ | _], track_ref: [_ | _]} = errors_on(changeset)
    end
  end
end
