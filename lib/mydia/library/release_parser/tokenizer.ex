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

  - Whitespace, `.`, `_` become token boundaries (the resulting separator
    span is discarded).
  - `[`, `]`, `(`, `)`, `{`, `}` are token boundaries and the enclosed
    tokens carry their bracket context.
  - Embedded dashes are split only against a fixed allow-list of
    compounds (`WEB-DL`, `WEB-Rip`, `H-265`, `H-264`, `DTS-HD`, `DTS-X`,
    `Hi10P-Hi10`). All other dashes stay un-split (`Spider-Man`,
    `Marvel's What-If`).
  """

  alias Mydia.Library.ReleaseParser.Token

  @compound_dashes MapSet.new([
                     "WEB-DL",
                     "WEB-RIP",
                     "BLU-RAY",
                     "H-265",
                     "H-264",
                     "DTS-HD",
                     "DTS-X",
                     "HI10P-HI10"
                   ])

  # Prefer parenthesized / bracketed years (V2 calls them "primary").
  @year_re_primary ~r/[\(\[](19\d{2}|20\d{2})[\)\]]/
  @year_re_secondary ~r/(?<![0-9])(19\d{2}|20\d{2})(?![0-9])/

  @resolution_re ~r/(?<![0-9a-zA-Z])(?:(?:480|540|576|720|1080|1440|2160|4320)[pi]|4K|8K|UHD)(?![a-zA-Z])/i

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
    scan(stripped, stripped, 0, nil, nil, []) |> Enum.reverse() |> apply_compound_dash_splits()
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

    resolution = first_match_pos(stripped, [@resolution_re])

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

  # State: (remaining, full_input, current_byte_pos, token_start_or_nil, bracket_or_nil, acc)
  # acc is a list of finished %Token{} values in reverse order.
  defp scan(<<>>, full, pos, start, bracket, acc) do
    emit_pending(full, pos, start, bracket, acc)
  end

  defp scan(<<byte, rest::binary>>, full, pos, start, bracket, acc)
       when byte in [?\s, ?., ?_, ?\t] do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 1, nil, bracket, acc)
  end

  defp scan(<<byte, rest::binary>>, full, pos, start, bracket, acc)
       when byte in [?[, ?\(, ?{] do
    acc = emit_pending(full, pos, start, bracket, acc)
    scan(rest, full, pos + 1, nil, bracket_context(byte), acc)
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

      [
        %Token{
          value: value,
          byte_offset: start_pos,
          byte_length: len,
          bracket_context: bracket
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

  defp apply_compound_dash_splits(tokens) do
    Enum.flat_map(tokens, fn token ->
      upper = String.upcase(token.value)

      if MapSet.member?(@compound_dashes, upper) do
        split_compound_dash(token)
      else
        [token]
      end
    end)
  end

  defp split_compound_dash(%Token{} = token) do
    case String.split(token.value, "-", parts: 2) do
      [left, right] ->
        left_len = byte_size(left)

        [
          %Token{
            value: left,
            byte_offset: token.byte_offset,
            byte_length: left_len,
            bracket_context: token.bracket_context
          },
          %Token{
            value: right,
            byte_offset: token.byte_offset + left_len + 1,
            byte_length: byte_size(right),
            bracket_context: token.bracket_context
          }
        ]

      _ ->
        [token]
    end
  end
end
