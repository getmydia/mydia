defmodule Mydia.Settings.QualityProfile.FreeleechPreferenceTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.QualityProfile
  alias Mydia.Settings.QualityProfile.FreeleechPreference

  defp attrs(value) do
    %{
      name: "Freeleech Test",
      quality_standards: %{preferred_resolutions: ["1080p"], freeleech_preference: value}
    }
  end

  defp profile(standards), do: %QualityProfile{name: "Test", quality_standards: standards}

  describe "changeset validation" do
    test "accepts ignore and prefer" do
      for value <- ["ignore", "prefer"] do
        assert QualityProfile.changeset(%QualityProfile{}, attrs(value)).valid?
      end
    end

    test "accepts a profile without the key" do
      assert QualityProfile.changeset(%QualityProfile{}, %{
               name: "No Key",
               quality_standards: %{preferred_resolutions: ["1080p"]}
             }).valid?
    end

    test "rejects any other value" do
      changeset = QualityProfile.changeset(%QualityProfile{}, attrs("always"))

      refute changeset.valid?

      assert {"freeleech_preference must be one of: ignore, prefer", _} =
               changeset.errors[:quality_standards]
    end
  end

  describe "prefer?/1" do
    test "is true only for prefer" do
      assert FreeleechPreference.prefer?(profile(%{freeleech_preference: "prefer"}))
      refute FreeleechPreference.prefer?(profile(%{freeleech_preference: "ignore"}))
      refute FreeleechPreference.prefer?(profile(%{}))
      refute FreeleechPreference.prefer?(profile(nil))
      refute FreeleechPreference.prefer?(nil)
    end
  end
end
