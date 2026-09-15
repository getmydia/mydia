defmodule Mydia.Upgrades.UpgradePolicyTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Upgrades
  alias Mydia.Upgrades.FileLanguages

  defp item(choice, metadata \\ %{original_language: "ja"}),
    do: %MediaItem{download_audio_language: choice, metadata: metadata}

  test "the server default treats English as acceptable after its own languages" do
    policy = Upgrades.upgrade_policy(item(nil), server_language: "original")

    assert policy.source == :server
    assert policy.languages == ["ja", "en"]
  end

  test "a server default that already names English is unchanged" do
    assert Upgrades.upgrade_policy(item(nil), server_language: "en").languages == ["en", "ja"]
  end

  test "a show's own choice is a request and gets no English floor" do
    policy = Upgrades.upgrade_policy(item("fr"), server_language: "original")

    assert policy.source == :show
    assert policy.languages == ["fr", "ja"]
  end

  test "no server preference stays no preference" do
    assert Upgrades.upgrade_policy(item(nil), server_language: nil).languages == []
  end

  describe "TMDB spoken languages" do
    test "count after English when the original language is not among them" do
      metadata = %{original_language: "en", spoken_languages: ["de", "pl"]}
      policy = Upgrades.upgrade_policy(item(nil, metadata), server_language: "original")

      assert policy.languages == ["en", "de", "pl"]
      refute FileLanguages.gap?(policy, {:known, ["de"]})
    end

    test "resolve string keys and three-letter codes" do
      metadata = %{"original_language" => "en", "spoken_languages" => ["ger", "pol"]}
      policy = Upgrades.upgrade_policy(item(nil, metadata), server_language: "original")

      assert policy.languages == ["en", "de", "pl"]
    end

    test "add nothing when the original language is spoken" do
      metadata = %{original_language: "en", spoken_languages: ["en", "zh"]}
      policy = Upgrades.upgrade_policy(item(nil, metadata), server_language: "original")

      assert policy.languages == ["en"]
      assert FileLanguages.gap?(policy, {:known, ["zh"]})
    end

    test "are ignored when the title has its own download audio choice" do
      metadata = %{original_language: "en", spoken_languages: ["de", "pl"]}
      policy = Upgrades.upgrade_policy(item("en", metadata), server_language: "original")

      assert policy.source == :show
      assert policy.languages == ["en"]
    end

    test "add nothing when TMDB sends none" do
      for metadata <- [
            %{original_language: "en"},
            %{original_language: "en", spoken_languages: []},
            %{original_language: "en", spoken_languages: [nil, "und"]}
          ] do
        policy = Upgrades.upgrade_policy(item(nil, metadata), server_language: "original")

        assert policy.languages == ["en"]
      end
    end

    test "add nothing without a known original language" do
      metadata = %{spoken_languages: ["de"]}
      policy = Upgrades.upgrade_policy(item(nil, metadata), server_language: "fr")

      assert policy.languages == ["fr", "en"]
    end
  end
end
