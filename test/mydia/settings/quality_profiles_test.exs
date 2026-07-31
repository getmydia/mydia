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

    # Whole-branch review finding 4: `min_upgrade_margin: data["..."]` cast
    # nil straight over the schema default of 5 whenever an older export
    # omitted the key - nil is not in Ecto's @empty_values, which is only
    # [""]. A nil margin then reads as 0 in the gate, and a delta of exactly
    # 0.0 counted as an upgrade: identical-quality churn, arriving silently
    # rather than because an operator chose it.
    test "keeps the schema default margin when a legacy export omits min_upgrade_margin" do
      legacy = legacy_json(name: "Legacy no margin", upgrade_until_quality: "1080p")

      assert {:ok, profile} = QualityProfiles.import_profile(legacy)
      assert profile.min_upgrade_margin == 5
    end

    test "honours an explicit min_upgrade_margin, including a deliberate 0" do
      json = """
      {
        "schema_version": 1,
        "name": "Explicit zero margin",
        "upgrade_until_score": 85,
        "min_upgrade_margin": 0,
        "quality_standards": {"preferred_resolutions": ["1080p"]}
      }
      """

      assert {:ok, profile} = QualityProfiles.import_profile(json)
      assert profile.min_upgrade_margin == 0
    end

    test "keeps the schema default when min_upgrade_margin is the wrong type" do
      json = """
      {
        "schema_version": 1,
        "name": "String margin",
        "upgrade_until_score": 85,
        "min_upgrade_margin": "5",
        "quality_standards": {"preferred_resolutions": ["1080p"]}
      }
      """

      assert {:ok, profile} = QualityProfiles.import_profile(json)
      assert profile.min_upgrade_margin == 5
    end

    test "keeps the schema default when upgrade_until_score is the wrong type" do
      json = """
      {
        "schema_version": 1,
        "name": "String score",
        "upgrade_until_score": "95",
        "quality_standards": {"preferred_resolutions": ["1080p"]}
      }
      """

      assert {:ok, profile} = QualityProfiles.import_profile(json)
      assert profile.upgrade_until_score == 85
    end

    test "keeps the schema default when upgrades_allowed is omitted" do
      json = """
      {
        "schema_version": 1,
        "name": "No upgrades key",
        "upgrade_until_score": 85,
        "quality_standards": {"preferred_resolutions": ["1080p"]}
      }
      """

      assert {:ok, profile} = QualityProfiles.import_profile(json)
      assert profile.upgrades_allowed == true
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
