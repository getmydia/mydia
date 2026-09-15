defmodule MydiaWeb.AudioLanguageComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.AudioLanguageComponents

  test "labels explicit languages in order" do
    html =
      render_component(&AudioLanguageComponents.audio_badge/1,
        languages: ["en", "ja"],
        assumed: false
      )

    assert html =~ "EN+JA"
    assert html =~ ~s(data-test="audio-badge")
    refute html =~ "assumed"
  end

  test "marks an assumed detection and names the languages in the tooltip" do
    html =
      render_component(&AudioLanguageComponents.audio_badge/1,
        languages: ["ja"],
        assumed: true,
        rank: 1
      )

    assert html =~ "JA (assumed)"
    assert html =~ "Japanese"
    assert html =~ "preference rank 1"
  end

  test "renders nothing when no language was detected" do
    html = render_component(&AudioLanguageComponents.audio_badge/1, languages: [], assumed: true)

    refute html =~ "audio-badge"
  end
end
