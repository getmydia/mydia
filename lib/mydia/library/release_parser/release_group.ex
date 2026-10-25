defmodule Mydia.Library.ReleaseParser.ReleaseGroup do
  @moduledoc """
  The release parser's release-group pre-pass.

  Detects a trailing release-group separator (`-GROUP`) before
  tokenization and rewrites the dash to a space so the tokenizer splits it
  cleanly. The dash before a trailing group has no semantic meaning we want
  to preserve; it just makes the codec/quality token downstream attach to
  the group name.

  ## Byte safety

  No `String.slice/3` or `String.length/1` calls anywhere, same rule as
  the rest of the release_parser/ tree.
  """

  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.ReleaseParser.Tokenizer
  alias Mydia.Library.ReleaseParser.Vocabulary

  # V2's release-group regex: a hyphen/dot prefix or double-space
  # prefix, then one or two `[A-Z0-9]+` groups, optionally followed by
  # a bracket site tag, optionally followed by whitespace and the end.
  @release_group_re ~r/(?:[-.]|\s{2,})([A-Z0-9]+(?:[.\s][A-Z0-9]+)?)(?:\[[^\]]+\])?\s*$/i

  # Reposters and indexers append their own tags after the group
  # (`-NTb-xpost`, `-RiVER-RP`). Mirrors the suffix list in Sonarr's
  # `ReleaseGroupParser.CleanReleaseGroupRegex`, minus `[N-Z-B]`, which
  # cannot survive the dash pre-pass here.
  @reposter_suffixes_re ~r/(?:-(?:RP|1|NZBGeek|Obfuscated|Scrambled|sample|Pre|postbot|xpost|Rakuv[a-z0-9]*|WhiteRev|BUYMORE|AsRequested|AlternativeToRequested|GEROV|Z0iDS3N|Chamele0n|4P|4Planet|AlteZachen|RePACKPOST))+$/i

  @doc """
  Detect a trailing release-group separator (`-GROUP` or `. GROUP`)
  and, when present, rewrite the separator to a space so the
  tokenizer cleanly separates the group from the preceding token.

  V2 normalizes `.` and `_` to spaces before running the regex; we
  replicate that for matching only (the rewritten input keeps the
  original separators except for the matched span).

  Returns `{prepared, group, group_offset}`, where `group_offset` is the
  byte offset of the separator in `prepared` (nil without a group).

  Reposter tags are cut from the matched copy only, so they still reach
  the tokenizer, after the group, where nothing reads them. The cut keeps
  a prefix of `filename`, so every offset below indexes both.
  """
  @spec strip_trailing(String.t()) ::
          {String.t(), String.t() | nil, non_neg_integer() | nil}
  def strip_trailing(filename) do
    stripped_for_match =
      filename
      |> Tokenizer.drop_extension()
      |> String.replace(@reposter_suffixes_re, "")

    normalized = String.replace(stripped_for_match, ~r/[._]/, " ")

    case codec_led_group(stripped_for_match, normalized) do
      {group, dash_offset} ->
        {replace_byte(filename, dash_offset, " "), group, dash_offset}

      nil ->
        strip_generic_release_group(filename, stripped_for_match, normalized)
    end
  end

  @doc """
  The pre-pass has already decided the trailing token is the release
  group, so it is not also a source. This keeps a group named after a
  scene abbreviation (`x264-TS`) from reading as a Telesync.
  """
  @spec drop_sources([Token.t()], non_neg_integer() | nil) :: [Token.t()]
  def drop_sources(tokens, nil), do: tokens

  def drop_sources(tokens, group_offset) do
    Enum.map(tokens, fn token ->
      if token.byte_offset > group_offset do
        %{token | candidates: Enum.reject(token.candidates, &(&1.label == :source))}
      else
        token
      end
    end)
  end

  # After a codec the dash is unambiguous, so the group may itself hold
  # dashes (`x264-Some-Group`, `x264-D-Z0N3`) or be bracketed with nothing
  # before it (`x264-[GRP]`, `x264.-[YTS.LT]`). @release_group_re reads
  # neither: it takes only the last dash part, and needs a bare group
  # before a bracket.
  @codec_led_group_re ~r/
    (?<![A-Z0-9])(?:[xh]\s?26[45]|hevc|avc|xvid|divx|av1|vp9)\s?
    (-)
    (?:
        \[([A-Z0-9][^\]]*)\]
      |
        ([A-Z0-9]+(?:-[A-Z0-9]+)+)(?:\[[^\]]+\])?
    )
    \s*$
  /ix

  # Offsets index `stripped` too: normalization swaps bytes one for one,
  # and the group keeps its own dots (`YTS.LT`).
  defp codec_led_group(stripped, normalized) do
    case Regex.run(@codec_led_group_re, normalized, return: :index) do
      [_, {dash_offset, 1} | groups] ->
        {start, len} = Enum.find(groups, &(elem(&1, 0) >= 0))

        stripped
        |> :binary.part(start, len)
        |> clean_dashed_group()
        |> sanitize_release_group()
        |> case do
          nil -> nil
          group -> {group, dash_offset}
        end

      _ ->
        nil
    end
  end

  # `REPACK-GRP` puts the release flag where the group goes; the flag is
  # not part of the name. A quality word further in means the run is more
  # metadata (`H264-Fra-Ac3-2-0-Eng`, `x264-DHD-Remux`, `HEVC-[10bit]`),
  # not a name.
  defp clean_dashed_group(group) do
    parts =
      group
      |> String.split("-")
      |> Enum.drop_while(&quality_marker_word?/1)

    if Enum.any?(parts, &quality_part?/1), do: "", else: Enum.join(parts, "-")
  end

  @bit_depth_re ~r/^\d{1,2}[-_ ]?bits?$/i
  @quality_labels [:codec, :source, :hdr, :audio, :language, :streaming_service]

  defp quality_part?(part) do
    quality_marker_word?(part) or Regex.match?(@bit_depth_re, part) or
      Enum.any?(Vocabulary.lookup(part), &(&1.label in @quality_labels))
  end

  defp replace_byte(binary, offset, replacement) do
    :binary.part(binary, 0, offset) <>
      replacement <> :binary.part(binary, offset + 1, byte_size(binary) - offset - 1)
  end

  defp strip_generic_release_group(filename, stripped_for_match, normalized) do
    case Regex.run(@release_group_re, normalized, return: :index) do
      [{full_start, _full_len}, {g_start, g_len}] ->
        group_name = :binary.part(normalized, g_start, g_len)
        # Check if the preceding token forms a known compound (e.g.
        # `AAC-LC`, `DTS-HD`) — if so, leave the dash intact.
        compound? = forms_known_compound?(stripped_for_match, full_start, group_name)

        cond do
          compound? ->
            {filename, nil, nil}

          group = sanitize_release_group(group_name) ->
            rewritten = rewrite_trailing_separator(filename, normalized)
            {rewritten, group, full_start}

          quality_marker_after_anchor?(group_name, stripped_for_match, full_start) ->
            # Not a group, but the dash still glues a quality word onto the
            # token before it (`2020-1080p-bluray`), and the tokenizer only
            # splits allow-listed compounds. Splitting it lets the classifier
            # see the word.
            {rewrite_trailing_separator(filename, normalized), nil, nil}

          true ->
            {filename, nil, nil}
        end

      _ ->
        {filename, nil, nil}
    end
  end

  # When the captured "group" is actually a known compound suffix
  # (e.g. `AAC-LC`, `DTS-HD`, `WEB-DL`, `DTS-X`), don't treat it as a
  # release group.
  @known_compound_suffixes MapSet.new(["LC", "HD", "DL", "RIP", "X", "MA", "265", "264"])

  defp forms_known_compound?(stripped, full_start, group_name) do
    String.upcase(group_name) in @known_compound_suffixes or
      blu_ray?(stripped, full_start, group_name)
  end

  # A trailing `Blu-ray` is the source, not a group named `ray`.
  defp blu_ray?(stripped, dash_offset, group_name) do
    String.downcase(group_name) == "ray" and dash_offset >= 3 and
      String.downcase(:binary.part(stripped, dash_offset - 3, 3)) == "blu"
  end

  # Replace the trailing separator in the original input. We find the
  # match position in the *normalized* form (which shares leading bytes
  # with the original) and rewrite the corresponding span in the
  # original — substituting any dot/underscore characters in the
  # separator with spaces.
  defp rewrite_trailing_separator(filename, normalized) do
    case Regex.run(@release_group_re, normalized, return: :index) do
      [{full_start, _full_len} | _] ->
        before = :binary.part(filename, 0, full_start)
        # Preserve the entire suffix from the match position onwards
        # but flatten the *first* character of the separator to space.
        suffix =
          :binary.part(filename, full_start + 1, byte_size(filename) - full_start - 1)

        before <> " " <> suffix

      _ ->
        filename
    end
  end

  # Reject candidates that are clearly not a release group: known
  # quality markers, single-letter, or starts with a digit indicating a
  # resolution that slipped through.
  @quality_marker_words MapSet.new(~w(
                            web bluray bdrip brrip webrip webdl hdtv dvd dvdrip dvdscr
                            remux hdr hdr10 hdr10+ dolbyvision dovi dv
                            atmos dts dts-x dts-hd truehd aac ac3 dd ddp eac3
                            hevc avc xvid divx vp9 av1 nvenc opus vorbis flac mp3
                            x264 x265 h264 h265
                            proper repack internal limited unrated extended theatrical hybrid
                            amzn nf atvp dsnp hmax hulu pmtp pcok stan
                            4k 8k uhd 720p 1080p 2160p 360p 480p 540p 576p 1440p 4320p
                            ddp5 ddp7 dd5 dd7 ddp51 ddp71 dd51 dd71 ddp20 dd20
                            aac20 aac51
                          ))

  # Token forms that the trailing-group regex sometimes captures (e.g.
  # `1080p.AAC` or `DDP5.1`). These should be rejected.
  @combined_marker_re ~r/^\d{3,4}[pPiIkK]?\.[A-Z0-9]+$/i
  @ddp_dd_channel_re ~r/^DD[P]?\d+(?:\.\d+)?$/i
  @dotted_codec_re ~r/^(?:[HX]\.?\d{3}|HEVC|AVC)$/i
  @contains_resolution_re ~r/\b(?:360p|480p|540p|576p|720p|1080p|1440p|2160p|4320p|4K|8K|UHD)\b/i
  @episode_marker_in_group_re ~r/^(?:S\d{1,3}E\d{1,4}|E\d{1,4})(?:[-\s.]?E?\d{1,4})*/i

  defp sanitize_release_group(group) do
    cond do
      String.downcase(group) in @quality_marker_words ->
        nil

      Regex.match?(@combined_marker_re, group) ->
        nil

      Regex.match?(@ddp_dd_channel_re, group) ->
        nil

      Regex.match?(@dotted_codec_re, group) ->
        nil

      # Group contains a resolution token — false positive from `.1080p`
      # being captured as part of a "compound" group.
      Regex.match?(@contains_resolution_re, group) ->
        nil

      # Group starts with an episode-range fragment (`E03.1080p`).
      Regex.match?(@episode_marker_in_group_re, group) ->
        nil

      # Single-character "groups" are almost always tokenizer artifacts
      # like the trailing `X` from `DTS-X`.
      byte_size(group) < 2 ->
        nil

      true ->
        group
    end
  end

  # Only in the metadata zone: before the first anchor a hyphenated word
  # is part of the title (`Spider-Web`), and splitting it would change it.
  defp quality_marker_after_anchor?(group_name, input, separator_offset) do
    anchors = Tokenizer.anchor_positions(input)

    quality_marker_word?(group_name) and
      separator_offset > Tokenizer.title_boundary(anchors, input)
  end

  defp quality_marker_word?(word), do: String.downcase(word) in @quality_marker_words
end
