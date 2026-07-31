defmodule Mydia.Settings.QualityProfilesTest do
  # async: false — the info-level logging test below raises the *global*
  # Logger level to :info so the Logger.info/2 macro actually evaluates and
  # emits its arguments. The rest of the suite runs at :warning
  # (config/test.exs); see test/mydia/jobs/download_monitor_logging_test.exs
  # for the same pattern.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Settings.QualityProfiles

  describe "importing legacy profile JSON" do
    test "translates a 480p resolution ceiling into the migration's equivalent score" do
      legacy = legacy_json(name: "Legacy 480p", upgrade_until_quality: "480p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.upgrade_until_score == 40
    end

    test "translates a 720p resolution ceiling into the migration's equivalent score" do
      legacy = legacy_json(name: "Legacy 720p", upgrade_until_quality: "720p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.upgrade_until_score == 60
    end

    test "translates a 1080p resolution ceiling into the migration's equivalent score" do
      legacy = legacy_json(name: "Legacy 1080p", upgrade_until_quality: "1080p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.upgrade_until_score == 85
    end

    test "translates a 2160p resolution ceiling into the migration's equivalent score" do
      legacy = legacy_json(name: "Legacy 2160p", upgrade_until_quality: "2160p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.upgrade_until_score == 95
    end

    test "falls back to the default score for an unrecognized resolution" do
      legacy = legacy_json(name: "Legacy weird", upgrade_until_quality: "8640p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.upgrade_until_score == 85
    end

    test "prefers an explicit upgrade_until_score when both keys are present" do
      json = """
      {
        "schema_version": 1,
        "name": "Both keys present",
        "upgrade_until_quality": "720p",
        "upgrade_until_score": 95,
        "quality_standards": {"preferred_resolutions": ["1080p"]}
      }
      """

      assert {:ok, profile} = QualityProfiles.import_profile(json)
      assert profile.upgrade_until_score == 95
    end

    test "logs the translation at info level so it is visible rather than silent" do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      legacy = legacy_json(name: "Logged import", upgrade_until_quality: "2160p")

      log =
        capture_log(fn ->
          assert {:ok, _profile} = QualityProfiles.import_profile(legacy)
        end)

      assert log =~ "upgrade_until_quality"
      assert log =~ "2160p"
      assert log =~ "95"
    end
  end

  defp legacy_json(fields) do
    Jason.encode!(%{
      "schema_version" => 1,
      "name" => Keyword.fetch!(fields, :name),
      "upgrades_allowed" => true,
      "upgrade_until_quality" => Keyword.fetch!(fields, :upgrade_until_quality),
      "quality_standards" => %{"preferred_resolutions" => ["1080p"]}
    })
  end
end
