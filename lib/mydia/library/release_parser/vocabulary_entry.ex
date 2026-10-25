defmodule Mydia.Library.ReleaseParser.VocabularyEntry do
  @moduledoc """
  One row in a vocabulary data file under `priv/release_parser/*.exs`.

  Each entry maps a set of case-insensitive `aliases` to a single
  `canonical` output value and a base `confidence`. Zone bonuses adjust
  the base confidence depending on whether the matched token sits in the
  title zone (before the earliest anchor) or in the metadata zone (after
  it).

  Flat fields rather than a nested map per AGENTS.md's struct-over-map
  guidance — adding a vocabulary entry is a one-line struct literal.
  """

  @enforce_keys [:label, :aliases, :canonical, :confidence]
  defstruct [
    :label,
    :aliases,
    :canonical,
    :confidence,
    title_zone_bonus: 0.0,
    metadata_zone_bonus: 0.0,
    # Matches only a token written in capitals. For abbreviations that are
    # also everyday words (`CAM` against "Cam"), where the capitals are
    # what marks the tag.
    uppercase_only: false
  ]

  @type label ::
          :codec
          | :source
          | :hdr
          | :audio
          | :language
          | :streaming_service
          | :release_group
          | atom()

  @type t :: %__MODULE__{
          label: label(),
          aliases: [String.t()],
          canonical: String.t(),
          confidence: float(),
          title_zone_bonus: float(),
          metadata_zone_bonus: float(),
          uppercase_only: boolean()
        }
end
