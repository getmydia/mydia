defmodule Mydia.Library.ReleaseParser.Tokenizer do
  @moduledoc """
  Splits a release-name string into byte-positioned `%Token{}` values and
  identifies anchor positions (year, resolution, episode marker) that
  bound the title zone.

  ## Boundary primitive

  The title is everything before the minimum byte position across the
  detected anchors. Preserves V2's proven heuristic.

  ## Byte-safety

  Every position is a byte offset into the input. Multi-byte UTF-8
  characters (Japanese, Korean, Cyrillic, accented Latin) are common in
  release names and must round-trip through `:binary.part/3` cleanly.
  **Do not introduce `String.slice/3` or `String.length/1` anywhere in
  this module** — they operate on graphemes, not bytes.

  ## Separator rules

  - Whitespace, `.`, `_` and the zero-width space become token
    boundaries (the resulting separator span is discarded), and so does
    `"` past the title boundary.
  - `[`, `]`, `(`, `)`, `{`, `}` are token boundaries and the enclosed
    tokens carry their bracket context and the opening bracket's offset.
  - Embedded dashes are split only against a fixed allow-list of
    compounds (`WEB-DL`, `WEB-Rip`, `H-265`, `H-264`, `DTS-HD`, `DTS-X`,
    `Hi10P-Hi10`). All other dashes stay un-split (`Spider-Man`,
    `Marvel's What-If`). `WEB-DL` and `WEB-Rip` stay whole before the
    title boundary, where the vocabulary reads them as one word.
  - A source glued to a resolution (`HDTV-720p`, `Bluray1080p`, Sonarr's
    file naming) is split in two, but only when the left part is a known
    source, so `Pilot-720p` stays whole. The reverse order (`720p-web`)
    splits the same way. `HD1080p` keeps only the resolution. Past the title
    boundary, a video or audio codec, a revision flag, a WEB compound or a
    remux dash-joined to anything (`BDRip-AVC`, `HEVC-10bit`, `x264-AAC`,
    `720p-FLAC`, `x264-REPACK-GRP`, `S1E1-WEB-DL`) is split off it; in the
    title (`Route-264`) it stays.
  """

  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.ReleaseParser.Vocabulary

  @compound_dashes MapSet.new([
                     "WEB-DL",
                     "WEB-RIP",
                     "H-265",
                     "H-264",
                     "DTS-HD",
                     "DTS-X",
                     "HI10P-HI10"
                   ])

  # Prefer parenthesized / bracketed years (V2 calls them "primary").
  @year_re_primary ~r/[\(\[](19\d{2}|20\d{2})[\)\]]/
  @year_re_secondary ~r/(?<![0-9])(19\d{2}|20\d{2})(?![0-9])/

  @resolution_heights "(?:360|480|540|576|720|1080|1440|2160|4320)[pi]"

  @resolution_re ~r/(?<![0-9a-zA-Z])(?:#{@resolution_heights}|4K|8K|UHD)(?![a-zA-Z])/i

  # A resolution glued to the word before it (`Bluray1080p`, `HD1080p`).
  # The lookbehind above rejects these, so the prefix is checked on its
  # own and the anchor lands on the digits, where the glued split puts
  # the resolution token.
  @glued_resolution_anchor_re ~r/(?<![0-9a-zA-Z])([a-zA-Z][a-zA-Z-]*?)-?(#{@resolution_heights})(?![a-zA-Z])/i

  # `HD` glued to a resolution says nothing the resolution doesn't, and is
  # not a source.
  @glued_resolution_noise ["HD"]

  @type anchors :: %{
          year: non_neg_integer() | nil,
          resolution: non_neg_integer() | nil,
          episode_marker: non_neg_integer() | nil
        }

  @doc """
  Tokenize a release-name string. Returns the ordered list of tokens.

  The filename's extension (`.mkv`, `.mp4`, etc.) is stripped before
  tokenization.
  """
  @spec tokenize(String.t()) :: [Token.t()]
  def tokenize(input) when is_binary(input) do
    stripped = drop_extension(input)
    boundary = title_boundary(anchor_positions(stripped), stripped)

    scannable = unquote_metadata(stripped, boundary)

    scan(scannable, scannable, 0, nil, nil, [])
    |> Enum.reverse()
    |> apply_glued_source_splits(boundary)
    |> apply_compound_dash_splits(boundary)
  end

  @doc """
  Anchor byte positions in the input.

  Year-inside-title carve-out: when the release name starts with a year
  before the earliest episode marker, that year is treated as part of
  the title, not as the year anchor — the documented
  "2001 A Space Odyssey S01E01" corner case from V2.
  """
  @spec anchor_positions(String.t()) :: anchors()
  def anchor_positions(input) when is_binary(input) do
    stripped = drop_extension(input)

    episode = first_match_pos(stripped, episode_markers())
    primary_year = first_capture_pos(stripped, @year_re_primary)

    year =
      if primary_year != nil do
        primary_year
      else
        first_match_pos(stripped, [@year_re_secondary])
      end

    resolution =
      [first_match_pos(stripped, [@resolution_re]), glued_resolution_pos(stripped)]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    %{
      year: year_after_episode_only(year, episode, primary_year),
      resolution: resolution,
      episode_marker: episode
    }
  end

  @doc """
  Lowest byte offset across all detected anchors, or `byte_size(input)`
  when no anchor is present. Used as the title-zone upper boundary.
  """
  @spec title_boundary(anchors(), String.t()) :: non_neg_integer()
  def title_boundary(anchors, input) do
    candidates =
      [anchors.year, anchors.resolution, anchors.episode_marker]
      |> Enum.reject(&is_nil/1)

    case candidates do
      [] -> byte_size(drop_extension(input))
      positions -> Enum.min(positions)
    end
  end

  @known_extensions ~w(
    mkv mp4 avi mov m4v ts webm flv wmv mpg mpeg vob ogv 3gp f4v rm rmvb
    mp3 m4a flac aac ogg opus wav
    srt ass ssa sub idx vtt
  )

  @doc """
  Drop a known media/subtitle extension from a release name.

  A blanket "anything after the last dot" strip would eat parts of
  release names (e.g. `Show...Name` -> `Show...`), so this only removes
  extensions from the known parser allow-list.
  """
  @spec drop_extension(String.t()) :: String.t()
  def drop_extension(input) when is_binary(input) do
    case Regex.run(~r/\.([A-Za-z0-9]{1,5})$/, input, return: :index) do
      [{ext_start, ext_len}, {_, _}] ->
        ext = :binary.part(input, ext_start + 1, ext_len - 1) |> String.downcase()

        if ext in @known_extensions do
          :binary.part(input, 0, ext_start)
        else
          input
        end

      _ ->
        input
    end
  end

  # ---- Internals ----

  defp episode_markers do
    [
      # S01E01 / S01-E01 / S01 E01 / S01.E01, with optional multi-episode tails.
      ~r/(?<![a-zA-Z])S\d{1,3}[-\s.]?E\d{1,4}(?:[-\s.]?E?\d{1,4})*(?![a-zA-Z])/i,
      ~r/(?<![a-zA-Z])\d{1,3}x\d{1,4}(?![a-zA-Z0-9])/i,
      ~r/(?<![a-zA-Z])S\d{1,3}(?![0-9a-zA-Z])/i,
      ~r/\b[Ss]eason[\s._]+\d{1,3}\b/,
      # Standalone absolute episode numbering (E18, E018, E1234) with no
      # season marker — common in anime. The digit-preceded lookbehind
      # keeps this from ever winning against a real S01E01 match (the
      # "E" there is always preceded by a digit), and the alnum
      # lookaround keeps it from matching inside words like "EAC3" or
      # "ETHEL".
      ~r/(?<![a-zA-Z0-9])E\d{2,4}(?![a-zA-Z0-9])/i
    ]
  end

  # Past the title boundary a double quote (`DVDRip."XviD"-GRP`) wraps a tag
  # and is a separator. In the title (`Show "Nick" S01E01`) it is kept. The
  # swap is byte for byte, so offsets and token values are unchanged.
  defp unquote_metadata(input, boundary) when boundary < byte_size(input) do
    head = :binary.part(input, 0, boundary)
    tail = :binary.part(input, boundary, byte_size(input) - boundary)
    head <> String.replace(tail, "\"", " ")
  end

  defp unquote_metadata(input, _boundary), do: input

  # State: (remaining, full_input, current_byte_pos, token_start_or_nil, bracket_or_nil, acc)
  # `bracket` is `{context, opening_offset}` inside brackets.
  # acc is a list of finished %Token{} values in reverse order.
  defp scan(<<>>, full, pos, start, bracket, acc) do
    emit_pending(full, pos, start, bracket, acc)
  end

  defp scan(<<byte, rest::binary>>, full, pos, start, bracket, acc)
       when byte in [?\s, ?., ?_, ?\t] do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 1, nil, bracket, acc)
  end

  # Zero-width space (U+200B), which some posters put before every word.
  defp scan(<<0xE2, 0x80, 0x8B, rest::binary>>, full, pos, start, bracket, acc) do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 3, nil, bracket, acc)
  end

  defp scan(<<byte, rest::binary>>, full, pos, start, bracket, acc)
       when byte in [?[, ?\(, ?{] do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 1, nil, {bracket_context(byte), pos}, acc)
  end

  defp scan(<<byte, rest::binary>>, full, pos, start, bracket, acc)
       when byte in [?], ?\), ?}] do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 1, nil, nil, acc)
  end

  defp scan(<<_byte, rest::binary>>, full, pos, nil, bracket, acc) do
    scan(rest, full, pos + 1, pos, bracket, acc)
  end

  defp scan(<<_byte, rest::binary>>, full, pos, start, bracket, acc) do
    scan(rest, full, pos + 1, start, bracket, acc)
  end

  defp emit_pending(_full, _pos, nil, _bracket, acc), do: acc

  defp emit_pending(full, end_pos, start_pos, bracket, acc) do
    len = end_pos - start_pos

    if len > 0 do
      value = :binary.part(full, start_pos, len)
      {context, opening} = bracket || {nil, nil}

      [
        %Token{
          value: value,
          byte_offset: start_pos,
          byte_length: len,
          bracket_context: context,
          bracket_offset: opening
        }
        | acc
      ]
    else
      acc
    end
  end

  defp bracket_context(?[), do: :bracket
  defp bracket_context(?\(), do: :paren
  defp bracket_context(?{), do: :brace

  defp first_match_pos(input, regexes) do
    Enum.reduce(regexes, nil, fn re, current ->
      case Regex.run(re, input, return: :index) do
        [{pos, _len} | _] -> min_or_take(current, pos)
        _ -> current
      end
    end)
  end

  defp min_or_take(nil, pos), do: pos
  defp min_or_take(curr, pos), do: min(curr, pos)

  # Year-before-episode carve-out: only fire when the year is at
  # position 0 (i.e. the title literally starts with the year, like
  # `2001 A Space Odyssey S01E01`). If a parenthesized year matched we
  # trust that unconditionally.
  defp year_after_episode_only(nil, _, _), do: nil
  defp year_after_episode_only(year, nil, _), do: year
  defp year_after_episode_only(year, _ep, primary_year) when primary_year != nil, do: year
  defp year_after_episode_only(0, _ep, _), do: nil
  defp year_after_episode_only(year, _, _), do: year

  # Capture the first capture group (used for parenthesized years where
  # the match start includes the bracket but we want the digit position).
  defp first_capture_pos(input, regex) do
    case Regex.run(regex, input, return: :index) do
      [_full, {pos, _len} | _] -> pos
      _ -> nil
    end
  end

  @glued_resolution_re ~r/^(.+?)(-?)(#{@resolution_heights})$/i

  defp glued_resolution_pos(input) do
    @glued_resolution_anchor_re
    |> Regex.scan(input, return: :index)
    |> Enum.find_value(fn [_full, {prefix_at, prefix_len}, {res_at, _}] ->
      if glued_prefix?(:binary.part(input, prefix_at, prefix_len)), do: res_at
    end)
  end

  defp glued_prefix?(word), do: source_word?(word) or noise_prefix?(word)

  defp noise_prefix?(word), do: String.upcase(word) in @glued_resolution_noise

  defp apply_glued_source_splits(tokens, boundary) do
    Enum.flat_map(tokens, fn %Token{} = token ->
      case source_then_resolution(token.value) do
        nil -> split_unglued(token, boundary)
        match -> split_glued(token, match)
      end
    end)
  end

  defp split_glued(%Token{} = token, [_, left, dash, right]) do
    left_len = byte_size(left)

    resolution = %Token{
      token
      | value: right,
        byte_offset: token.byte_offset + left_len + byte_size(dash),
        byte_length: byte_size(right)
    }

    if noise_prefix?(left),
      do: [resolution],
      else: [%Token{token | value: left, byte_length: left_len}, resolution]
  end

  defp split_unglued(%Token{} = token, boundary) do
    cond do
      resolution_then_source?(token.value) -> split_compound_dash(token)
      metadata_zone?(token, boundary) -> split_dashed_codecs(token)
      true -> [token]
    end
  end

  # The mirror order, a resolution then its source (`720p-web`). The
  # resolution anchors the token, so this is never a title word.
  @resolution_then_word_re ~r/^#{@resolution_heights}-([a-zA-Z]+)$/i

  defp resolution_then_source?(value) do
    case Regex.run(@resolution_then_word_re, value) do
      [_, word] -> has_label?(word, :source)
      nil -> false
    end
  end

  defp remux_part?(part), do: Enum.any?(Vocabulary.lookup(part), &(&1.canonical == "REMUX"))

  # Codec words do turn up in titles (`Route-264`, `Code-Hevc`,
  # `Avc-Station`), so a dash run is split only once it reaches past the
  # title boundary. Anchor-less anime names carry their quality in
  # brackets (`(1280x720_x264-AAC)`), so a bracketed token counts too,
  # unless it is the leading `[Group]` tag.
  defp metadata_zone?(%Token{} = token, boundary) do
    token.byte_offset + token.byte_length > boundary or
      (token.bracket_context != nil and token.byte_offset > 1)
  end

  # A source (or `HD`) followed by its resolution, dash optional.
  defp source_then_resolution(value) do
    case Regex.run(@glued_resolution_re, value) do
      [_, left, _, _] = match -> if glued_prefix?(left), do: match
      nil -> nil
    end
  end

  # A codec dash-joined to its neighbours (`BDRip-AVC`, `HEVC-10bit`,
  # `1080p-x264-AC3`, a group the pre-pass did not claim) comes off as its
  # own token, in the metadata zone only (see metadata_zone?/2). The other
  # dash runs stay joined (`WEB-DLRip`, `Fra-Ac3`).
  # A bare `264` counts so `H.264-GRP` still pairs its `H` and `264`.
  # Audio codecs split the same way (`720p-AAC`, `AC3-REPACK`), unless the
  # whole run is itself a vocabulary word (`E-AC3`, `AAC-LC`), which a split
  # would mangle into a different codec.
  # A WEB compound or a remux in the run (`S1E1-WEB-DL-1080p`,
  # `WEB-DL-GRP`, `Hybrid-REMUX`) comes off the same way; the compound is
  # rejoined first so it splits off whole.
  defp split_dashed_codecs(%Token{value: value} = token) do
    parts = value |> String.split("-") |> join_web_compounds()

    if length(parts) > 1 and Vocabulary.lookup(value) == [] and
         Enum.any?(parts, &codec_part?/1) do
      parts
      |> runs_around_codecs()
      |> Enum.map(fn {offset, run} ->
        %Token{
          token
          | value: run,
            byte_offset: token.byte_offset + offset,
            byte_length: byte_size(run)
        }
      end)
    else
      [token]
    end
  end

  # A revision flag between the codec and the group (`x264-REPACK-TLA`)
  # comes off too, or it stays glued to the group name.
  defp codec_part?(part) do
    part in ["264", "265"] or has_label?(part, :codec) or has_label?(part, :audio) or
      has_label?(part, :proper) or has_label?(part, :repack) or remux_part?(part) or
      web_compound?(part)
  end

  # Only the dashed WEB compounds: a bare `Web` part is a title word as often
  # as a source (`Spider-Web`).
  defp web_compound?(part), do: String.contains?(part, "-") and has_label?(part, :source)

  defp join_web_compounds([head, next | rest]) do
    joined = head <> "-" <> next

    if String.upcase(head) == "WEB" and has_label?(joined, :source),
      do: [joined | join_web_compounds(rest)],
      else: [head | join_web_compounds([next | rest])]
  end

  defp join_web_compounds(parts), do: parts

  # `{relative_offset, value}` for each codec part and each dash-joined run
  # of other parts between them; empty parts (a leading dash) are dropped.
  defp runs_around_codecs(parts) do
    {runs, pending, _offset} =
      Enum.reduce(parts, {[], nil, 0}, fn part, {runs, pending, offset} ->
        next = offset + byte_size(part) + 1

        cond do
          part == "" ->
            {flush(runs, pending), nil, next}

          codec_part?(part) ->
            {[{offset, part} | flush(runs, pending)], nil, next}

          pending == nil ->
            {runs, {offset, part}, next}

          true ->
            {start, run} = pending
            {runs, {start, run <> "-" <> part}, next}
        end
      end)

    Enum.reverse(flush(runs, pending))
  end

  defp flush(runs, nil), do: runs
  defp flush(runs, pending), do: [pending | runs]

  # `WEB-DL` is not itself a vocabulary alias; the compound split below
  # turns it into one.
  defp source_word?(word) do
    MapSet.member?(@compound_dashes, String.upcase(word)) or has_label?(word, :source)
  end

  defp has_label?(word, label), do: Enum.any?(Vocabulary.lookup(word), &(&1.label == label))

  # Before the title boundary a WEB compound stays whole: split, its `Web`
  # half takes the title-zone penalty that keeps `Madame.Web` a title, and
  # its `DL` half joins the title. Whole, it is a vocabulary word of its own.
  @web_compounds ["WEB-DL", "WEB-RIP"]

  defp apply_compound_dash_splits(tokens, boundary) do
    Enum.flat_map(tokens, fn token ->
      upper = String.upcase(token.value)

      cond do
        upper in @web_compounds and token.byte_offset < boundary -> [token]
        MapSet.member?(@compound_dashes, upper) -> split_compound_dash(token)
        true -> [token]
      end
    end)
  end

  defp split_compound_dash(%Token{} = token) do
    case String.split(token.value, "-", parts: 2) do
      [left, right] ->
        left_len = byte_size(left)

        [
          %Token{token | value: left, byte_length: left_len},
          %Token{
            token
            | value: right,
              byte_offset: token.byte_offset + left_len + 1,
              byte_length: byte_size(right)
          }
        ]

      _ ->
        [token]
    end
  end
end
