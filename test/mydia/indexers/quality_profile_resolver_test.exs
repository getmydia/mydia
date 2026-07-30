defmodule Mydia.Indexers.QualityProfileResolverTest do
  use Mydia.DataCase, async: true

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  describe "resolve/1" do
    test "returns the item's own profile and ignores the instance default" do
      own = quality_profile_fixture(%{name: "own-profile"})
      other = quality_profile_fixture(%{name: "instance-default"})
      {:ok, _} = Settings.set_default_quality_profile(other.id)

      media_item = media_item_fixture(%{quality_profile_id: own.id})

      assert %QualityProfile{} = resolved = QualityProfileResolver.resolve(media_item)
      assert resolved.id == own.id
    end

    test "falls back to the instance default when the item has no profile" do
      default = quality_profile_fixture(%{name: "instance-default"})
      {:ok, _} = Settings.set_default_quality_profile(default.id)

      media_item = media_item_fixture()
      assert is_nil(media_item.quality_profile_id)

      assert %QualityProfile{} = resolved = QualityProfileResolver.resolve(media_item)
      assert resolved.id == default.id
    end

    test "returns nil and warns when there is no profile and no instance default" do
      media_item = media_item_fixture()

      log =
        capture_log(fn ->
          assert is_nil(QualityProfileResolver.resolve(media_item))
        end)

      assert log =~ "no size or resolution bounds"
    end
  end
end
