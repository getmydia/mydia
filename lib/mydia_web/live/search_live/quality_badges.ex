defmodule MydiaWeb.SearchLive.QualityBadges do
  @moduledoc """
  The quality badges shown on each search result row.
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.Structs.Quality

  @doc "Badge text and daisyUI colour for each quality attribute the result carries."
  def get_quality_badges(%SearchResult{quality: nil}), do: []

  def get_quality_badges(%SearchResult{quality: quality}) do
    badges = []

    # Resolution badge (primary - blue)
    badges =
      if quality.resolution do
        [%{text: quality.resolution, color: "badge-primary"} | badges]
      else
        badges
      end

    # Source badge (secondary - purple/gray)
    badges =
      if quality.source do
        [%{text: quality.source, color: "badge-secondary"} | badges]
      else
        badges
      end

    # Codec badge (accent - cyan)
    badges =
      if quality.codec do
        [%{text: quality.codec, color: "badge-accent"} | badges]
      else
        badges
      end

    # Audio badge (ghost - subtle)
    badges =
      if quality.audio do
        [%{text: quality.audio, color: "badge-ghost"} | badges]
      else
        badges
      end

    # Special indicators
    badges =
      if Quality.hdr?(quality) do
        [%{text: "HDR", color: "badge-warning"} | badges]
      else
        badges
      end

    badges =
      if quality.proper do
        [%{text: "PROPER", color: "badge-success"} | badges]
      else
        badges
      end

    badges =
      if quality.repack do
        [%{text: "REPACK", color: "badge-info"} | badges]
      else
        badges
      end

    Enum.reverse(badges)
  end
end
