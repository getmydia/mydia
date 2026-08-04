defmodule Mydia.Settings.QualityProfileTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.QualityProfile

  describe "upgrade cutoff validation" do
    test "accepts a cutoff and margin within range" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Upgradeable",
          upgrade_until_score: 85,
          min_upgrade_margin: 5,
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      assert changeset.valid?
    end

    test "rejects a cutoff above 100" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Bad",
          upgrade_until_score: 101,
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      refute changeset.valid?
      assert %{upgrade_until_score: _} = errors_on(changeset)
    end

    test "rejects a negative margin" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Bad",
          min_upgrade_margin: -1,
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      refute changeset.valid?
      assert %{min_upgrade_margin: _} = errors_on(changeset)
    end
  end

  describe "quality_standards excluded_sources validation" do
    test "accepts the cam-tier vocabulary" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Excl Accepts",
          quality_standards: %{
            preferred_resolutions: ["1080p"],
            excluded_sources: Mydia.Quality.Sources.cam_tier()
          }
        })

      assert changeset.valid?
    end

    test "accepts an empty list" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Excl Empty",
          quality_standards: %{preferred_resolutions: ["1080p"], excluded_sources: []}
        })

      assert changeset.valid?
    end

    test "rejects an unknown source" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Excl Unknown",
          quality_standards: %{
            preferred_resolutions: ["1080p"],
            excluded_sources: ["NotARealSource"]
          }
        })

      refute changeset.valid?
      assert %{quality_standards: [msg]} = errors_on(changeset)
      assert msg =~ "NotARealSource"
    end

    test "rejects a non-list value" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Excl NonList",
          quality_standards: %{preferred_resolutions: ["1080p"], excluded_sources: "Telesync"}
        })

      refute changeset.valid?
    end
  end

  # Mydia.Quality.Sources.detect/1 folds "bdrip" into "BluRay" for the indexer
  # search/grab path, but the V3 release parser still emits canonical "BDRip"
  # for on-disk files, and that value flows through Mydia.Upgrades.Attrs into
  # scoring. So "BDRip" must remain selectable as a preference.
  describe "quality_standards preferred_sources validation" do
    test "accepts BDRip: the V3 parser still emits it for on-disk files" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Preferred BDRip",
          quality_standards: %{preferred_resolutions: ["1080p"], preferred_sources: ["BDRip"]}
        })

      assert changeset.valid?
    end

    test "accepts the remaining source vocabulary" do
      changeset =
        QualityProfile.changeset(%QualityProfile{}, %{
          name: "Preferred Sources",
          quality_standards: %{
            preferred_resolutions: ["1080p"],
            preferred_sources: [
              "BluRay",
              "REMUX",
              "WEB-DL",
              "WEBRip",
              "HDTV",
              "SDTV",
              "DVD",
              "DVDRip"
            ]
          }
        })

      assert changeset.valid?
    end
  end

  describe "excluded sources as a hard violation" do
    test "a file whose source is excluded scores zero and reports the violation" do
      profile = %QualityProfile{
        name: "Excl Violation",
        quality_standards: %{excluded_sources: ["Telesync", "CAM"]}
      }

      result =
        QualityProfile.score_media_file(profile, %{resolution: "1080p", source: "Telesync"})

      assert result.score == 0.0
      assert [violation] = result.violations
      assert violation =~ "Telesync"
    end

    test "a file with an allowed source is unaffected" do
      profile = %QualityProfile{
        name: "Excl Allowed",
        quality_standards: %{excluded_sources: ["Telesync", "CAM"]}
      }

      result = QualityProfile.score_media_file(profile, %{resolution: "1080p", source: "BluRay"})

      assert result.violations == []
      assert result.score > 0.0
    end

    test "a file with an unknown source is unaffected" do
      profile = %QualityProfile{
        name: "Excl Unknown Source",
        quality_standards: %{excluded_sources: ["Telesync"]}
      }

      result = QualityProfile.score_media_file(profile, %{resolution: "1080p"})

      assert result.violations == []
    end
  end
end
