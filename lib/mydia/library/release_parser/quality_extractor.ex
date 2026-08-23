defmodule Mydia.Library.ReleaseParser.QualityExtractor do
  @moduledoc """
  Stage 5 of the V3 release parser: project the resolver's
  `quality_tokens` into a `%Quality{}` struct, matching V2's raw and
  canonical-form outputs.

  Two flavors of output, controlled by `opts[:standardize]`:

  - `false` (default) — raw token values, matching V2's default API.
    `BluRay` stays `"BluRay"`, `x264` stays `"x264"`, `DDP5.1` stays
    `"DDP5.1"`.
  - `true` — canonical forms (`"H.264/AVC"`, `"Blu-ray"`,
    `"Dolby Digital Plus 5.1"`, `"2160p (4K)"`).

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

  # ---- Raw projection (matches V2 raw output) ----

  defp build_raw(quality_tokens, all_tokens, next_by_token) do
    resolution = extract_resolution(quality_tokens)
    source = extract_source(quality_tokens, next_by_token)
    codec = extract_codec(quality_tokens, all_tokens, next_by_token)
    {hdr_format, dolby_vision} = extract_hdr(quality_tokens)
    audio = extract_audio(quality_tokens, next_by_token)

    %Quality{
      resolution: resolution,
      source: source,
      codec: codec,
      hdr_format: hdr_format,
      dolby_vision: dolby_vision,
      audio: audio
    }
  end

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
  # post-split tokens).

  defp extract_source(quality_tokens, next_by_token) do
    case Enum.find(quality_tokens, &(&1.label == :source)) do
      nil ->
        nil

      entry ->
        raw = token_text(entry)
        rejoin_web_compound(raw, entry, next_by_token)
    end
  end

  defp rejoin_web_compound(raw, entry, next_by_token) do
    if String.upcase(raw) == "WEB" do
      case next_token(entry.token, next_by_token) do
        %Token{value: value} ->
          upper = String.upcase(value)

          cond do
            upper == "DL" -> "WEB-DL"
            upper == "RIP" -> "WEB-Rip"
            true -> raw
          end

        _ ->
          raw
      end
    else
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

  # Defensive fold, not a load-bearing one: Resolver.@singleton_labels treats
  # :hdr as a singleton, and resolve_one_label/2 strips every losing :hdr
  # candidate before quality_tokens is built, so this producer receives at
  # most one :hdr-labeled token per release. The scan-and-fold shape mirrors
  # QualityParser.extract_hdr/1, which scans a release title's raw text with
  # a regex and genuinely can see several HDR tokens (no resolver sits
  # between it and the string), so it keeps this shape for consistency and
  # to stay correct if the resolver's singleton constraint on :hdr is ever
  # relaxed.
  defp extract_hdr(quality_tokens) do
    quality_tokens
    |> Enum.filter(&(&1.label == :hdr))
    |> Enum.reduce({nil, false}, fn entry, {base, dv} ->
      case Hdr.from_release_token(token_text(entry)) do
        :dolby_vision -> {base, true}
        {:base, found} -> {base || found, dv}
        :unknown -> {base, dv}
      end
    end)
  end

  # --- Audio ---
  #
  # Audio is the most adjacency-prone field. Tokens like `DDP5.1`,
  # `DTS-HD.MA`, `TrueHD.7.1`, `AAC 2.0` get split on dots, spaces, and
  # dashes. Rebuild the V2 canonical *raw* string.

  defp extract_audio(quality_tokens, next_by_token) do
    case Enum.find(quality_tokens, &(&1.label == :audio)) do
      nil ->
        nil

      entry ->
        raw = token_text(entry)
        rejoin_audio(raw, entry, next_by_token)
    end
  end

  defp rejoin_audio(raw, entry, next_by_token) do
    upper = String.upcase(raw)

    cond do
      # DTS-HD: tokenizer compound-dash split produces DTS, HD as two
      # tokens. The vocab matches `DTS-HD` from `DTS` (after rejoin).
      # Then ".MA" may follow as a third token. We handle that case
      # below.
      upper in ["DTS"] ->
        rejoin_dts(entry, next_by_token, raw)

      # TrueHD: optional channel spec (`TrueHD 7.1` → `TrueHD 7.1`)
      upper == "TRUEHD" ->
        rejoin_trailing_channel(raw, entry, next_by_token)

      # AAC: optional channel spec
      upper in ["AAC", "AAC-LC"] ->
        rejoin_trailing_channel(raw, entry, next_by_token)

      # DDP / DD: may have channel suffix as separate token (`DDP5` `1` → `DDP5.1`).
      Regex.match?(~r/^DDP\d+$/i, raw) or Regex.match?(~r/^DD\d+$/i, raw) ->
        rejoin_trailing_channel_dot(raw, entry, next_by_token)

      # OPUS: with channels
      upper == "OPUS" ->
        rejoin_trailing_channel(raw, entry, next_by_token)

      true ->
        raw
    end
  end

  # Handle DTS rejoin: DTS-HD (with optional .MA) or DTS-X. Both are
  # adjacent dash compounds the tokenizer splits.
  defp rejoin_dts(entry, next_by_token, raw) do
    case next_token(entry.token, next_by_token) do
      %Token{value: hd_value, byte_offset: ho, byte_length: hl} = hd_token
      when hd_value in ["HD", "hd", "Hd"] ->
        sep_len = ho - (entry.token.byte_offset + entry.token.byte_length)

        if sep_len == 1 do
          rejoined = "DTS-HD"

          case next_token(hd_token, next_by_token) do
            %Token{value: ma_value, byte_offset: mo}
            when ma_value in ["MA", "ma", "Ma"] ->
              if mo == ho + hl + 1 do
                "DTS-HD.MA"
              else
                rejoined
              end

            _ ->
              rejoined
          end
        else
          raw
        end

      %Token{value: x_value, byte_offset: xo}
      when x_value in ["X", "x"] ->
        sep_len = xo - (entry.token.byte_offset + entry.token.byte_length)
        if sep_len == 1, do: "DTS-X", else: raw

      _ ->
        raw
    end
  end

  # Rejoin TrueHD/AAC/Opus with trailing channel notation: `TrueHD 7.1`
  # becomes `TrueHD 7.1`. The channels arrive as separate tokens
  # `7` and `1` after the dot split.
  defp rejoin_trailing_channel(raw, entry, next_by_token) do
    case channel_after(entry.token, next_by_token) do
      nil -> raw
      ch -> "#{raw} #{ch}"
    end
  end

  # Rejoin DDP/DD with channel suffix via dot: `DDP5` followed by `1` → `DDP5.1`.
  defp rejoin_trailing_channel_dot(raw, entry, next_by_token) do
    case next_token(entry.token, next_by_token) do
      %Token{value: digit, byte_offset: to}
      when digit in ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"] ->
        head_end = entry.token.byte_offset + entry.token.byte_length

        # Must be adjacent (separated by a single dot byte)
        if to == head_end + 1 do
          "#{raw}.#{digit}"
        else
          raw
        end

      _ ->
        raw
    end
  end

  # Detect a 2-digit channel suffix (e.g. `7` `1` after `TrueHD`).
  defp channel_after(%Token{} = token, next_by_token) do
    n1 = next_token(token, next_by_token)
    n2 = if n1, do: next_token(n1, next_by_token), else: nil

    if is_digit_token?(n1) and is_digit_token?(n2) do
      "#{n1.value}.#{n2.value}"
    else
      nil
    end
  end

  defp is_digit_token?(%Token{value: v}), do: Regex.match?(~r/^\d+$/, v)
  defp is_digit_token?(_), do: false

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

  defp token_key(%Token{byte_offset: offset, byte_length: length}), do: {offset, length}

  # ---- Standardization (matches V2's standardize_quality/1 outputs exactly) ----

  defp standardize(%Quality{} = q) do
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

      Regex.match?(~r/^ddp(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(value, "Dolby Digital Plus")

      Regex.match?(~r/^ac3$/i, normalized) ->
        "Dolby Digital"

      Regex.match?(~r/^dd(\d+\.?\d*)?$/i, normalized) ->
        extract_channels(value, "Dolby Digital")

      String.contains?(normalized, "dts-hd") and String.contains?(normalized, "ma") ->
        "DTS-HD Master Audio"

      String.contains?(normalized, "dts-hd") ->
        "DTS-HD High Resolution Audio"

      Regex.match?(~r/^dts-x$/i, normalized) ->
        "DTS:X"

      Regex.match?(~r/^dts$/i, normalized) ->
        "DTS"

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
