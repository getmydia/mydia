defmodule Mydia.Upgrades.UpgradePolicyTest do
  use ExUnit.Case, async: true

  alias Mydia.Media.MediaItem
  alias Mydia.Upgrades

  defp item(choice),
    do: %MediaItem{download_audio_language: choice, metadata: %{original_language: "ja"}}

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
end
