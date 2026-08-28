defmodule MydiaWeb.MediaLive.Show.SubtitleBadgesTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.SubtitleComponents

  defp track(language, opts \\ []) do
    %{
      track_id: Keyword.get(opts, :track_id, 1),
      language: language,
      title: language,
      format: "srt",
      embedded: Keyword.get(opts, :embedded, false),
      origin: Keyword.get(opts, :origin, :provider),
      deliverable: true,
      offset_ms: 0,
      resync_state: Keyword.get(opts, :resync_state)
    }
  end

  defp badges(tracks) do
    render_component(&SubtitleComponents.subtitle_badges/1, tracks: tracks, id: "mf-1")
  end

  test "renders nothing when the file has no tracks" do
    assert badges([]) =~ ~r/\A\s*\z/
  end

  test "renders one badge per language" do
    html = badges([track("en"), track("es", track_id: 2)])

    assert html =~ "EN"
    assert html =~ "ES"
  end

  test "deduplicates a language carried by two tracks" do
    html = badges([track("en", origin: :embedded), track("en", track_id: 2, origin: :provider)])

    document = LazyHTML.from_fragment(html)
    codes = LazyHTML.query(document, "[data-subtitle-code]") |> Enum.to_list()

    assert length(codes) == 1
  end

  test "caps at three codes and collapses the rest into a plus-N badge" do
    tracks =
      ["en", "es", "fr", "de", "pt"]
      |> Enum.with_index()
      |> Enum.map(fn {lang, i} -> track(lang, track_id: i) end)

    html = badges(tracks)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "[data-subtitle-code]") |> Enum.count() == 3
    assert html =~ "+2"
  end

  test "renders three codes with no overflow badge" do
    tracks =
      ["en", "es", "fr"]
      |> Enum.with_index()
      |> Enum.map(fn {lang, i} -> track(lang, track_id: i) end)

    html = badges(tracks)

    assert LazyHTML.from_fragment(html)
           |> LazyHTML.query("[data-subtitle-code]")
           |> Enum.count() == 3

    refute html =~ "+0"
    refute html =~ "+1"
  end

  test "marks a code whose track declined to sync, with the reason as a title" do
    html = badges([track("en", resync_state: "low_confidence")])

    assert html =~ "Could not match the audio confidently"
    assert html =~ ~s|data-subtitle-sync="declined"|
  end

  test "does not mark a successful or unattempted sync" do
    for state <- ["ok", "already_synced", nil] do
      html = badges([track("en", resync_state: state)])
      refute html =~ ~s|data-subtitle-sync="declined"|
    end
  end

  test "marks the language when one of several tracks in it declined" do
    html =
      badges([
        track("en", track_id: 1, resync_state: "ok"),
        track("en", track_id: 2, resync_state: "too_few_cues")
      ])

    assert html =~ ~s|data-subtitle-sync="declined"|
    assert html =~ "Too few subtitle lines to match reliably"
  end
end
