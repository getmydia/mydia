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
end
