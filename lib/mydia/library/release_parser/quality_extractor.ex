defmodule Mydia.Library.ReleaseParser.QualityExtractor do
  @moduledoc """
  Stage 5 of the V3 release parser: project the resolver's
  `quality_tokens` into a `%Quality{}` struct.

  Two flavors of output, controlled by `opts[:standardize]`:

  - `false` (default) - the canonical labels shared with the rest of the
    app (`Mydia.Quality`, the scorers): resolution `"2160p"`, source
    `"BluRay"` / `"WEB-DL"` / `"WEBRip"` / `"REMUX"`, codec `"H.265"` or
    the encoder `"x264"`, audio `"DD+ 5.1"` / `"AC3 5.1"` /
    `"DTS-HD MA 5.1"` / `"TrueHD 7.1"`. Spelling variants of one value
    (`HEVC`, `h265`; `BDRip`, `BRRip`; `DDP5.1`, `EAC3`) fold into one label.
  - `true` - display strings (`"H.265/HEVC"`, `"Blu-ray"`,
    `"Dolby Digital Plus 5.1"`, `"2160p (4K)"`), projected from the
    canonical labels.

  ## Adjacency rejoin

  The tokenizer splits on dots and dashes, so compound tokens like
  `DDP5.1`, `H.264`, `WEB-DL`, `DTS-HD.MA`, `2160p-NVENC` arrive as
  multiple tokens. This module rejoins them using the original token
  stream (`resolver.all_tokens`) so V2-compatible raw values come back
  out the other side.

  ## Byte-safety

  No `String.slice/3` / `String.length/1` — same rule as the rest of
  `release_parser/`.
  """

  alias Mydia.Library.Hdr
  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.Structs.Quality

  @doc """
  Build a `%Quality{}` from the resolver result.

  Accepts either the full resolver result map (preferred — provides
  `all_tokens` for adjacency) or the legacy `[quality_token]` list
  shape for backwards compatibility with older callers.
  """
  @spec extract(map() | [map()], keyword()) :: Quality.t()
  def extract(resolver_result, opts \\ [])

  def extract(%{quality_tokens: qts, all_tokens: tokens}, opts) when is_list(tokens) do
    do_extract(qts, tokens, opts)
  end

  def extract(quality_tokens, opts) when is_list(quality_tokens) do
    do_extract(quality_tokens, [], opts)
  end

  defp do_extract(quality_tokens, all_tokens, opts) do
    standardize? = Keyword.get(opts, :standardize, false)
    next_by_token = next_token_index(all_tokens)
    raw = build_raw(quality_tokens, all_tokens, next_by_token)

    if standardize? do
      standardize(raw)
    else
      raw
    end
  end

  # ---- Projection: rejoin adjacent tokens, then map to canonical labels ----

  defp build_raw(quality_tokens, all_tokens, next_by_token) do
    resolution = extract_resolution(quality_tokens)
    source = extract_source(quality_tokens, next_by_token)
    codec = extract_codec(quality_tokens, all_tokens, next_by_token)
    {hdr_format, dolby_vision} = extract_hdr(quality_tokens, all_tokens, next_by_token)
    audio = extract_audio(quality_tokens, next_by_token)

    %Quality{
      resolution: canonical_resolution(resolution),
      source: canonical_source(source),
      codec: canonical_codec(codec),
      hdr_format: hdr_format,
      dolby_vision: dolby_vision,
      audio: audio
    }
  end

  # ---- Canonical labels ----
  #
  # The rejoin code below produces whatever spelling the release used;
  # these fold each spelling into the one label the scorers and
  # `Mydia.Quality.Attrs` understand. Unknown values pass through.

  defp canonical_resolution(nil), do: nil

  defp canonical_resolution(value) do
    down = String.downcase(value)

    cond do
      down in ["4k", "uhd"] -> "2160p"
      down == "8k" -> "4320p"
      down == "1440p" -> "1080p"
      Regex.match?(~r/^\d{3,4}i$/, down) -> String.replace_suffix(down, "i", "p")
      true -> value
    end
  end

  defp canonical_source(nil), do: nil

  defp canonical_source(value) do
    case String.downcase(value) do
      v when v in ["bluray", "bd", "bdrip", "brrip"] -> "BluRay"
      "web" -> "WEB-DL"
      v when v in ["web-rip", "webrip"] -> "WEBRip"
      "remux" -> "REMUX"
      "dvdrip" -> "DVDRip"
      _ -> value
    end
  end

  defp canonical_codec(nil), do: nil

  # The classifier reads `HEVC,` from a comma-separated tag list; the
  # comma is not part of the codec.
  defp canonical_codec(value) do
    value = String.trim_trailing(value, ",")
    down = String.downcase(value)

    cond do
      down == "hevc" -> "H.265"
      down == "avc" -> "H.264"
      m = Regex.run(~r/^([hx])[\s.]?(26[45])$/, down) -> canonical_h26x(m)
      down == "xvid" -> "XviD"
      down == "divx" -> "DivX"
      down == "vp9" -> "VP9"
      down == "av1" -> "AV1"
      true -> value
    end
  end

  defp canonical_h26x([_, "h", digits]), do: "H.#{digits}"
  defp canonical_h26x([_, "x", digits]), do: "x#{digits}"

  defp canonical_audio_name(name) when name in ["ddp", "eac3", "e-ac3", "e-ac-3", "eac3d", "dd+"],
    do: "DD+"

  defp canonical_audio_name(name) when name in ["dd", "ac3", "ac3d"], do: "AC3"

  defp canonical_audio_name(name) when name in ["dts-hd.ma", "dts-hd ma", "dtshdma"],
    do: "DTS-HD MA"

  defp canonical_audio_name(name) when name in ["dts-hd", "dtshd"], do: "DTS-HD"
  defp canonical_audio_name(name) when name in ["dts-x", "dts:x", "dtsx"], do: "DTS:X"
  defp canonical_audio_name("dts"), do: "DTS"
  defp canonical_audio_name("truehd"), do: "TrueHD"
  defp canonical_audio_name(name) when name in ["aac", "aac-lc"], do: "AAC"
  defp canonical_audio_name(name) when name in ["flac", "2xflac", "flacx2"], do: "FLAC"
  defp canonical_audio_name("opus"), do: "Opus"
  defp canonical_audio_name("vorbis"), do: "Vorbis"
  defp canonical_audio_name("mp3"), do: "MP3"
  defp canonical_audio_name(_), do: nil

  # --- Resolution ---
  #
  # Pull out just the `\d{3,4}[pi]` / `4K` / `UHD` portion of the token
  # so `2160p-NVENC` returns `2160p`. Normalize uppercase `P` → `p`.

  @resolution_re ~r/(\d{3,4}[pPiI]|4[kK]|8[kK]|[uU][hH][dD])/

  defp extract_resolution(quality_tokens) do
    case Enum.find(quality_tokens, &(&1.label == :resolution)) do
      nil ->
        nil

      entry ->
        raw = token_text(entry)

        case Regex.run(@resolution_re, raw, capture: :all_but_first) do
          [matched] -> normalize_resolution_case(matched)
          _ -> raw
        end
    end
  end

  defp normalize_resolution_case(value) do
    if Regex.match?(~r/^\d+[pPiI]$/, value) do
      String.replace(value, ~r/[PI]$/, fn s -> String.downcase(s) end)
    else
      value
    end
  end

  # --- Source ---
  #
  # Rejoin WEB → WEB-DL / WEB-Rip if the next adjacent token is `DL`
  # or `Rip` (the tokenizer's compound-dash split produces these
  # post-split tokens). Every other source takes the vocabulary's
  # canonical value, which is what folds `HDTS`, `PDVD` and `TS` into
  # `Telesync`.

  defp extract_source(quality_tokens, next_by_token) do
    case Enum.find(quality_tokens, &(&1.label == :source)) do
      nil ->
        nil

      entry ->
        raw = token_text(entry)

        if String.upcase(raw) == "WEB" do
          rejoin_web_compound(raw, entry, next_by_token)
        else
          vocabulary_value(entry) || raw
        end
    end
  end

  defp vocabulary_value(%{value: value}) when is_binary(value), do: value
  defp vocabulary_value(_entry), do: nil

  defp rejoin_web_compound(raw, entry, next_by_token) do
    case next_token(entry.token, next_by_token) do
      %Token{value: value} ->
        case String.upcase(value) do
          "DL" -> "WEB-DL"
          "RIP" -> "WEB-Rip"
          _ -> raw
        end

      _ ->
        raw
    end
  end

  # --- Codec ---
  #
  # Rejoin `H` + `264` / `265` and `x` + `264` / `265` after the
  # tokenizer split on dots. The vocabulary catches the no-dot variants
  # (`x264`, `h264`, `HEVC`, `AVC`) directly; this handler covers the
  # dotted forms.

  defp extract_codec(quality_tokens, all_tokens, next_by_token) do
    case Enum.find(quality_tokens, &(&1.label == :codec)) do
      nil ->
        find_dotted_codec(all_tokens)

      entry ->
        raw = token_text(entry)
        merged = maybe_rejoin_codec(raw, entry, next_by_token)
        merged
    end
  end

  defp find_dotted_codec(all_tokens) do
    all_tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [tok, next] ->
      if dotted_codec_pair?(tok, next) do
        "#{tok.value}.#{next.value}"
      else
        nil
      end
    end)
  end

  defp dotted_codec_pair?(%Token{value: head, byte_offset: ho, byte_length: hl}, %Token{
         value: tail,
         byte_offset: to
       }) do
    head_upper = String.upcase(head)
    # Head must be H or X (single char), tail must be 264 or 265, and the
    # two must be separated by exactly one byte (the dot).
    head_upper in ["H", "X"] and tail in ["264", "265"] and to == ho + hl + 1
  end

  defp dotted_codec_pair?(_, _), do: false

  defp maybe_rejoin_codec(raw, entry, next_by_token) do
    # Some codec tokens (XviD, HEVC) survive as a single token — nothing to rejoin.
    upper = String.upcase(raw)

    if upper in [
         "X264",
         "X265",
         "H264",
         "H265",
         "HEVC",
         "AVC",
         "XVID",
         "DIVX",
         "VP9",
         "AV1",
         "NVENC"
       ] do
      raw
    else
      # If the token is just "H" or "X" (rare; usually the vocab handles
      # `x264`/`h264` directly), check the next token for `264`/`265`.
      case next_token(entry.token, next_by_token) do
        %Token{value: digits, byte_offset: to} when digits in ["264", "265"] ->
          head_end = entry.token.byte_offset + entry.token.byte_length

          if to == head_end + 1 do
            "#{raw}.#{digits}"
          else
            raw
          end

        _ ->
          raw
      end
    end
  end

  # --- HDR ---

  # The resolver passes every :hdr token, in token order, because they
  # stack: `DV.HDR10` is a Dolby Vision layer over an HDR10 base, and
  # keeping only one of them loses either the layer or the base. The fold
  # is QualityParser.extract_hdr/1's: the first base token wins and Dolby
  # Vision is sticky.
  #
  # The vocabulary's canonical value is folded, not the raw token text, so
  # a listed tag (`[HEVC, HDR10, DV]`) reads the same as a dotted one. Two
  # spellings split across tokens are rejoined here: `HDR10.PLUS` and
  # `Dolby.Vision`. "Dolby" has no vocabulary entry of its own, so it is
  # only read when the classifier left it unclaimed, which keeps a title
  # word ("Dolby.Vision.Story.2020") out.
  defp extract_hdr(quality_tokens, all_tokens, next_by_token) do
    {base, dv} =
      quality_tokens
      |> Enum.filter(&(&1.label == :hdr))
      |> Enum.reduce({nil, false}, fn entry, {base, dv} ->
        case Hdr.from_release_token(hdr_text(entry, next_by_token)) do
          :dolby_vision -> {base, true}
          {:base, found} -> {base || found, dv}
          :unknown -> {base, dv}
        end
      end)

    {base, dv or spaced_dolby_vision?(all_tokens, next_by_token)}
  end

  defp hdr_text(%{value: "HDR10", token: %Token{} = token}, next_by_token) do
    if next_word(token, next_by_token) == "plus", do: "HDR10+", else: "HDR10"
  end

  defp hdr_text(%{value: value}, _next_by_token) when is_binary(value), do: value
  defp hdr_text(entry, _next_by_token), do: token_text(entry)

  defp spaced_dolby_vision?(all_tokens, next_by_token) do
    Enum.any?(all_tokens, fn %Token{value: value, candidates: candidates} = token ->
      candidates == [] and String.downcase(value) == "dolby" and
        next_word(token, next_by_token) == "vision"
    end)
  end

  # The next token's text, downcased, without the comma of a listed tag
  # set (`Dolby Vision, WEB-DL`).
  defp next_word(%Token{} = token, next_by_token) do
    case next_token(token, next_by_token) do
      %Token{value: value} -> value |> String.downcase() |> String.trim_trailing(",")
      nil -> nil
    end
  end

  # --- Audio ---
  #
  # Audio is the most adjacency-prone field. Tokens like `DDP5.1`,
  # `DTS-HD.MA`, `TrueHD.7.1`, `AAC 2.0` get split on dots, spaces, and
  # dashes, so each audio token is rebuilt from its neighbours into a
  # canonical label and its channels.
  #
  # A release can list several tracks (`Esp DD2.0, Ing DTS-HD5.1`), and
  # the one reported is the best in the scorers' tier order, so a dub
  # listed first does not hide the lossless original. `Atmos` is not a
  # track: beside TrueHD it is the `TrueHD Atmos` tier, beside DD+ it has
  # no tier of its own and is dropped, and alone it is all the release
  # says.

  @audio_tiers [
    "TrueHD Atmos",
    "DTS:X",
    "TrueHD",
    "DTS-HD MA",
    "DTS-HD",
    "FLAC",
    "DD+",
    "DTS",
    "AC3",
    "AAC",
    "Opus",
    "Vorbis",
    "MP3"
  ]

  defp extract_audio(quality_tokens, next_by_token) do
    {atmos, tracks} =
      quality_tokens
      |> Enum.filter(&(&1.label == :audio))
      |> Enum.split_with(&(String.upcase(token_text(&1)) == "ATMOS"))

    tracks
    |> Enum.map(&(&1 |> audio_track(next_by_token) |> with_atmos(atmos != [])))
    |> Enum.min_by(&audio_tier/1, fn -> nil end)
    |> audio_label(atmos)
  end

  defp with_atmos({"TrueHD", channels}, true), do: {"TrueHD Atmos", channels}
  defp with_atmos(track, _atmos?), do: track

  defp audio_tier({label, _channels}) do
    Enum.find_index(@audio_tiers, &(&1 == label)) || length(@audio_tiers)
  end

  defp audio_label(nil, []), do: nil
  defp audio_label(nil, [_ | _]), do: "Atmos"
  defp audio_label({label, nil}, _atmos), do: label
  defp audio_label({label, channels}, _atmos), do: "#{label} #{channels}"

  defp audio_track(entry, next_by_token) do
    {name, fused} = entry |> token_text() |> keep_dd_plus(entry) |> split_fused_channels()
    {name, last, fused} = extend_dts(String.upcase(name), name, entry.token, fused, next_by_token)
    label = canonical_audio_name(String.downcase(name)) || name
    {label, audio_channels(fused, last, next_by_token)}
  end

  # `AAC2` (from `AAC2.0`), `DDP51`, `DTS-HD5`: the digits glued onto the
  # codec start its channel layout. The whole value is checked first,
  # since `EAC3` and `MP3` end in digits that are not channels.
  defp split_fused_channels(raw) do
    with nil <- canonical_audio_name(String.downcase(raw)),
         [_, name, digits] <- Regex.run(~r/^(.+?)(\d{1,2})$/, raw),
         label when is_binary(label) <- canonical_audio_name(String.downcase(name)) do
      {name, digits}
    else
      _ -> {raw, ""}
    end
  end

  # `token_text/1` drops trailing `+`, which would turn `DD+` into plain `DD`.
  defp keep_dd_plus("DD", %{token: %Token{value: value}}) do
    if String.upcase(value) == "DD+", do: "DD+", else: "DD"
  end

  defp keep_dd_plus(raw, _entry), do: raw

  # DTS compounds arrive split: `DTS-HD.MA` as `DTS` `HD` `MA`, `DTS-X` as
  # `DTS` `X`, and the shorthands `DTS-MA`, `DTSHD-MA` and `DTS-HR` (high
  # resolution) the same way. `DTS-ES` is plain DTS with its channels
  # after the `ES`. Returns the rebuilt name, the last token it used, and
  # any channel digits fused onto that token (`MA5` in `DTS-HD.MA5.1`).
  defp extend_dts("DTS", name, token, "", next_by_token) do
    case adjacent_token(token, next_by_token) do
      %Token{value: value} = next ->
        case String.upcase(value) do
          up when up in ["HD", "HR"] -> extend_ma(next, "DTS-HD", next_by_token)
          "X" -> {"DTS-X", next, ""}
          "ES" -> {name, next, ""}
          _ -> extend_ma(token, name, next_by_token)
        end

      nil ->
        {name, token, ""}
    end
  end

  defp extend_dts("DTSHD", _name, token, "", next_by_token),
    do: extend_ma(token, "DTS-HD", next_by_token)

  defp extend_dts(_upper, name, token, fused, _next_by_token), do: {name, token, fused}

  defp extend_ma(token, fallback, next_by_token) do
    with %Token{value: value} = ma <- adjacent_token(token, next_by_token),
         [_, digits] <- Regex.run(~r/^MA(\d{0,2})(?:-.*)?$/i, value) do
      {"DTS-HD MA", ma, digits}
    else
      _ -> {fallback, token, ""}
    end
  end

  # Channels come glued whole (`DDP51`), glued then split on the dot
  # (`DDP5` `1`, or `AAC2 0` with a space), or as two digit tokens after
  # the codec (`TrueHD.7.1`, `DD 5 1`), possibly past an `Atmos`
  # (`TrueHD.Atmos.7.1`).
  defp audio_channels(<<a, b>>, _last, _next_by_token) when a in ?0..?9 and b in ?0..?9,
    do: <<a, ?., b>>

  defp audio_channels(<<a>>, last, next_by_token) when a in ?0..?9 do
    case last |> adjacent_token(next_by_token) |> channel_digit() do
      nil -> nil
      b -> <<a, ?., b>>
    end
  end

  defp audio_channels(_fused, last, next_by_token) do
    n1 = last |> next_token(next_by_token) |> skip_atmos(next_by_token)
    n2 = next_token(n1, next_by_token)

    with a when a != nil <- channel_digit(n1),
         b when b != nil <- channel_digit(n2) do
      <<a, ?., b>>
    end
  end

  defp skip_atmos(%Token{value: value} = token, next_by_token) do
    if String.upcase(value) == "ATMOS", do: next_token(token, next_by_token), else: token
  end

  defp skip_atmos(nil, _next_by_token), do: nil

  # One digit, or one digit before the comma of a track list
  # (`Esp DD2.0,Ing DTS-HD5.1` tokenizes as `DD2` `0,Ing`): commas do not
  # split tokens.
  defp channel_digit(%Token{value: <<d>>}) when d in ?0..?9, do: d
  defp channel_digit(%Token{value: <<d, ?,, _::binary>>}) when d in ?0..?9, do: d
  defp channel_digit(_), do: nil

  # The next token, when only one separator byte sits between the two.
  defp adjacent_token(%Token{byte_offset: offset, byte_length: length} = token, next_by_token) do
    case next_token(token, next_by_token) do
      %Token{byte_offset: next_offset} = next when next_offset == offset + length + 1 -> next
      _ -> nil
    end
  end

  # --- Helpers ---

  defp token_text(%{token: %Token{value: value}}), do: strip_trailing_punct_bytes(value)
  defp token_text(%{value: value}) when is_binary(value), do: strip_trailing_punct_bytes(value)
  defp token_text(_), do: nil

  # Strip trailing `+`, `!`, etc. from the raw token text so values
  # like `DD+` round-trip as `DD`. Mirrors the classifier's punctuation
  # fallback for vocab lookup.
  defp strip_trailing_punct_bytes(""), do: ""

  defp strip_trailing_punct_bytes(value) when is_binary(value) do
    size = byte_size(value)
    last = :binary.at(value, size - 1)

    if last in ~c"+!?'" and not preserve_trailing_punct?(value) do
      strip_trailing_punct_bytes(binary_part(value, 0, size - 1))
    else
      value
    end
  end

  # Don't strip `+` from `HDR10+` — it's a meaningful suffix there.
  defp preserve_trailing_punct?(value) do
    upper = String.upcase(value)
    upper in ["HDR10+"]
  end

  defp next_token_index(all_tokens) do
    all_tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Map.new(fn [current, next] -> {token_key(current), next} end)
  end

  defp next_token(%Token{} = current, next_by_token) do
    Map.get(next_by_token, token_key(current))
  end

  defp next_token(nil, _next_by_token), do: nil

  defp token_key(%Token{byte_offset: offset, byte_length: length}), do: {offset, length}

  # ---- Standardization (matches V2's standardize_quality/1 outputs exactly) ----

  @doc """
  Projects a `%Quality{}` of canonical labels (what `extract/2` emits by
  default) into display strings such as `"Blu-ray"`, `"2160p (4K)"`,
  `"Dolby Digital Plus 5.1"`. Input spellings the parser used to emit (`"4K"`,
  `"DDP5.1"`, `"BDRip"`) are still accepted.

  Public so a caller holding quality values from another source, such as the
  analyzed columns on a media file, can bring them into the same vocabulary the
  parser emits under `standardize: true`, instead of maintaining a second
  mapping table that would drift from this one.
  """
  @spec standardize(Quality.t()) :: Quality.t()
  def standardize(%Quality{} = q) do
    %Quality{
      resolution: standardize_resolution(q.resolution),
      source: standardize_source(q.source),
      codec: standardize_codec(q.codec),
      # HDR is already canonical coming out of extract_hdr/1; no raw string
      # form remains to standardize.
      hdr_format: q.hdr_format,
      dolby_vision: q.dolby_vision,
      audio: standardize_audio(q.audio)
    }
  end

  defp standardize_resolution(nil), do: nil

  defp standardize_resolution(value) do
    normalized = String.downcase(value)

    cond do
      normalized in ["2160p", "4k", "uhd"] -> "2160p (4K)"
      normalized == "1080p" -> "1080p (Full HD)"
      normalized == "720p" -> "720p (HD)"
      normalized in ["4320p", "8k"] -> "4320p (8K)"
      normalized in ["576p", "480p"] -> "#{value} (SD)"
      true -> value
    end
  end

  defp standardize_source(nil), do: nil

  defp standardize_source(value) do
    normalized = String.downcase(value)

    cond do
      normalized in ["bluray", "bdrip", "brrip"] -> "Blu-ray"
      normalized == "remux" -> "Remux"
      normalized == "web-dl" -> "WEB-DL"
      normalized == "webrip" -> "WEBRip"
      normalized == "web-rip" -> "WEBRip"
      normalized == "web" -> "WEB"
      normalized == "hdtv" -> "HDTV"
      normalized in ["dvd", "dvdrip", "dvdscr"] -> "DVD"
      true -> value
    end
  end

  defp standardize_codec(nil), do: nil

  defp standardize_codec(value) do
    normalized = String.downcase(value)

    cond do
      Regex.match?(~r/^[hx][\s.]?265$/i, normalized) -> "H.265/HEVC"
      normalized == "hevc" -> "H.265/HEVC"
      Regex.match?(~r/^[hx][\s.]?264$/i, normalized) -> "H.264/AVC"
      normalized == "avc" -> "H.264/AVC"
      normalized == "xvid" -> "XviD"
      normalized == "divx" -> "DivX"
      normalized == "vp9" -> "VP9"
      normalized == "av1" -> "AV1"
      normalized == "nvenc" -> "NVENC"
      true -> value
    end
  end

  defp standardize_audio(nil), do: nil

  defp standardize_audio(value) do
    normalized = String.downcase(value)

    cond do
      Regex.match?(~r/^eac3$/i, normalized) ->
        "Dolby Digital Plus"

      Regex.match?(~r/^(ddp|dd\+)\s?(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(value, "Dolby Digital Plus")

      Regex.match?(~r/^ac3$/i, normalized) ->
        "Dolby Digital"

      Regex.match?(~r/^ac3\s\d+\.?\d*$/i, normalized) ->
        extract_channels(String.replace(value, ~r/^ac3\s/i, ""), "Dolby Digital")

      Regex.match?(~r/^dd(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(value, "Dolby Digital")

      String.contains?(normalized, "dts-hd") and String.contains?(normalized, "ma") ->
        "DTS-HD Master Audio"

      String.contains?(normalized, "dts-hd") ->
        "DTS-HD High Resolution Audio"

      Regex.match?(~r/^dts[-:]x$/i, normalized) ->
        "DTS:X"

      Regex.match?(~r/^dts$/i, normalized) ->
        "DTS"

      String.contains?(normalized, "truehd atmos") ->
        extract_channels(value, "Dolby TrueHD Atmos")

      String.contains?(normalized, "truehd") ->
        extract_channels(value, "Dolby TrueHD")

      Regex.match?(~r/^atmos$/i, normalized) ->
        "Dolby Atmos"

      Regex.match?(~r/^aac-lc/i, normalized) ->
        "AAC-LC"

      Regex.match?(~r/^aac/i, normalized) ->
        extract_channels(value, "AAC")

      true ->
        value
    end
  end

  defp extract_channels(value, base_name) do
    case Regex.run(~r/(\d+\.?\d*)/, value) do
      [_, channels] -> "#{base_name} #{channels}"
      _ -> base_name
    end
  end
end
