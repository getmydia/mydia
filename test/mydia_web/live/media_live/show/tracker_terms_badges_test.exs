defmodule MydiaWeb.MediaLive.Show.TrackerTermsBadgesTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Indexers.Structs.TrackerTerms
  alias MydiaWeb.MediaLive.Show.TrackerTermsBadges

  defp render_terms(terms) do
    html = render_component(&TrackerTermsBadges.terms_badges/1, id: "row", terms: terms)
    LazyHTML.from_fragment(html)
  end

  defp text(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp present?(doc, selector), do: Enum.any?(LazyHTML.query(doc, selector))

  test "full freeleech shows FL" do
    doc = render_terms(%TrackerTerms{download_volume_factor: 0.0})
    assert text(doc, "#row-freeleech") == "FL"
  end

  test "half leech shows the download percentage" do
    doc = render_terms(%TrackerTerms{download_volume_factor: 0.5})
    assert text(doc, "#row-freeleech") == "50%"
  end

  test "double upload shows the multiplier" do
    doc = render_terms(%TrackerTerms{upload_volume_factor: 2.0})
    assert text(doc, "#row-upload") == "2x up"
    refute present?(doc, "#row-freeleech")
  end

  test "a fractional upload multiplier keeps its decimals" do
    doc = render_terms(%TrackerTerms{upload_volume_factor: 1.5})
    assert text(doc, "#row-upload") == "1.5x up"
  end

  test "a private tracker shows the private icon" do
    doc = render_terms(%TrackerTerms{private?: true})
    assert present?(doc, "#row-private")
  end

  test "normal, unknown or malformed terms render nothing" do
    for terms <- [
          nil,
          %TrackerTerms{},
          %TrackerTerms{download_volume_factor: -1.0},
          %TrackerTerms{download_volume_factor: 0.996},
          %TrackerTerms{download_volume_factor: 1.0, upload_volume_factor: 1.0, private?: false}
        ] do
      doc = render_terms(terms)

      refute present?(doc, "#row-freeleech")
      refute present?(doc, "#row-upload")
      refute present?(doc, "#row-private")
    end
  end
end
