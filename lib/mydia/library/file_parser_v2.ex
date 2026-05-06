defmodule Mydia.Library.FileParser.V2 do
  @moduledoc """
  Sequential pattern-based media file parser (Version 2).

  This parser uses a PTN (Parse Torrent Name) inspired approach where:
  1. Each pattern is applied to the filename sequentially
  2. Matched portions are extracted and removed from the text
  3. What remains after all patterns is the title

  ## Algorithm

  ```
  filename = "Movie.Title.2020.1080p.BluRay.x264-GROUP.mkv"

  Apply patterns sequentially:
    - Year pattern: Match "2020" → Remove → year=2020
    - Resolution: Match "1080p" → Remove → resolution=1080p
    - Source: Match "BluRay" → Remove → source=BluRay
    - Codec: Match "x264" → Remove → codec=x.264
    - Release group: Match "-GROUP" → Remove → group=GROUP

  Remaining text: "Movie Title" ✓
  ```

  ## Benefits

  - **Robust**: Patterns handle variations automatically
  - **Maintainable**: Add pattern once instead of every variant
  - **Scalable**: Gracefully handles edge cases
  - **Industry Standard**: Aligns with PTN/GuessIt approach

  ## References

  - PTN: https://github.com/divijbindlish/parse-torrent-name
  - GuessIt: https://github.com/guessit-io/guessit
  - Analysis: docs/file_parser_analysis.md
  """

  require Logger

  alias Mydia.Library.SampleDetector
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  @type media_type :: :movie | :tv_show | :unknown

  # Keep backward-compatible type alias
  @type parse_result :: ParsedFileInfo.t()

  # Regex patterns from Phase 1
  # Order matters: match longer patterns first (DTS-HD before DTS, AAC-LC before AAC, DDP before DD)
  @audio_pattern ~r/
    \b
    (?:
      DTS-HD(?:[\s.]MA)?                  # DTS-HD.MA, DTS-HD MA, DTS-HD (must be before DTS)
      |DTS-X                               # DTS-X (must be before DTS)
      |DTS                                 # Plain DTS
      |DDP(?:\d+[\s.]?\d*)?                # DDP, DDP5.1, DDP51, DDP7.1 (must be before DD)
      |DD(?:\d+[\s.]?\d*)?                 # DD, DD5.1, DD51, DD7.1
      |EAC3(?:\d+[\s.]?\d*)?               # E-AC3 (same as DDP)
      |TrueHD(?:[\s.]\d+[\s.]?\d*)?        # TrueHD, TrueHD 7.1, TrueHD 7 1
      |Atmos
      |AAC-LC(?:[\s.]\d+[\s.]?\d*)?        # AAC-LC (must be before AAC)
      |AAC[\s.]?\d+[\s.]?\d*               # AAC2.0, AAC 2.0, AAC 2 0 (with numbers)
      |AAC                                 # Plain AAC (after AAC with numbers)
      |AC3
      |OPUS(?:\d+[\s.]?\d*)?               # OPUS, OPUS2.0
      |MP3
      |FLAC
      |(?:[257]ch)
    )
    \b
  /xi

  # Video codec regex list for extraction
  @codec_pattern ~r/
    \b
    (?:
      [hxHX][\s.]?26[45]                  # x264, x.264, x 264, h264, h.264, h 264, x265, h265, etc.
      |HEVC|AVC                            # HEVC, AVC
      |XviD|DivX                           # Legacy codecs
      |VP9|AV1                             # Modern codecs
      |NVENC|QSV|AMF|VCE|VideoToolbox      # Hardware encoders
    )
    \b
  /xi

  # Matches: 1080p in "Movie.1080p.mkv", [360p-DivX], (720p), 4K, etc.
  @resolution_pattern ~r/(?:^|[^\d])(\d{3,4}[pP]|4K|8K|UHD)(?:$|[^\d])/i

  # Source pattern - order matters: match longer patterns first (WEB-DL before WEB)
  # WEB is included but validated in extract_source to avoid matching titles like "Madame.Web"
  @source_pattern ~r/
    \b
    (?:
      REMUX
      |BluRay|BDRip|BRRip
      |WEB-DL                            # WEB-DL (specific, safe to match)
      |WEBRip                            # WEBRip (specific, safe to match)
      |WEB                               # Plain WEB (validated in handler)
      |HDTV
      |DVDScr                            # DVDScr (screener, must be before DVDRip)
      |DVDRip                            # DVDRip (must be before DVD)
      |DVD                               # Plain DVD
    )
    \b
  /xi

  # HDR pattern - includes Dolby Vision with space and DV abbreviation
  @hdr_pattern ~r/(?:\bHDR10\+|\b(?:DolbyVision|Dolby[\s.]Vision|DoVi|DV|HDR10|HDR)\b)/i
  # HDR profile pattern (P5, P8, etc.)
  @hdr_profile_pattern ~r/\bP[0-9]+\b/i

  # Additional noise patterns
  @bit_depth_pattern ~r/\b(8|10|12)[\s-]?bits?\b/i
  @encoder_pattern ~r/[-_. ](NVENC|QSV|AMF|VCE|VideoToolbox)\b/i

  # Match any content in square brackets (typically quality/metadata tags, not titles)
  @bracket_contents_pattern ~r/\[[^\]]+\]/i

  # Streaming service identifiers and other release noise
  @extra_noise_pattern ~r/\b(PROPER|REPACK|INTERNAL|LIMITED|UNRATED|DIRECTORS?\.CUT|EXTENDED|THEATRICAL|HYBRID|AMZN|ATVP|DSNP|HMAX|HULU|NF|PMTP|PCOK|STAN|iT|MA)\b/i
  @streaming_service_pattern ~r/\b(AMZN|ATVP|DSNP|HMAX|HULU|NF|PMTP|PCOK|STAN|iT|MA)\b/i
  @language_pattern ~r/\b(MULTi|MULTI|DUAL|DUBBED|SUBBED|KORSUB|FRENCH|TRUEFRENCH|GERMAN|SPANISH|ITALIAN|JAPANESE)\b/i
  @audio_channels_pattern ~r/\b[257]\s+1\b/i
  @vmaf_pattern ~r/\bVMAF\d+(?:\.\d+)?\b/i

  # Year pattern - prioritize parenthesized/bracketed years (tolerant of malformed/reversed brackets)
  @year_pattern_primary ~r/[\(\[\]\)\s]*\b(19\d{2}|20\d{2})\b[\(\[\]\)\s]*/

  # Standalone years without brackets (e.g., Movie.2020.1080p)
  @year_pattern_secondary ~r/[\s._-](19\d{2}|20\d{2})(?:[\s._-]|$)/

  # Release group pattern - hyphen, dot, or space prefix with optional site tag in brackets
  # Matches groups like "-GROUP", " POOLTED", "-MeM.GP", "-GROUP[site]"
  # Allows optional trailing whitespace to handle cases where brackets were removed
  # The $ anchor ensures this only matches at the end, preventing false matches on title words
  # The pattern also requires multiple spaces before the group to avoid matching single-space-separated title words
  @release_group_pattern ~r/(?:[-.]|\s{2,})([A-Z0-9]+(?:[.\s][A-Z0-9]+)?)(?:\[[^\]]+\])?\s*$/i

  # Rating pattern recognition
  @rating_pattern ~r/\b(G|PG|PG-13|R|NC-17|NR|TV-Y|TV-Y7|TV-G|TV-PG|TV-14|TV-MA)\b/i

  # Pull runtime from metadata in filename if exists
  @runtime_pattern ~r/\b\d+[-]min\b/i

  # Episode regex pattern, e.g. S03E21
  @episode_pattern ~r/[._-]?S\d{1,2}[._-]?E\d{1,2}/i

  # --- Extraction & Validation Patterns ---
  @year_extract_pattern ~r/(19\d{2}|20\d{2})/
  @resolution_extract_pattern ~r/(\d{3,4}[pP]|4K|8K|UHD)/i
  @web_word_pattern ~r/\bWEB\b/i
  @codec_space_pattern ~r/^[hxHX]\s26[45]$/i
  @dolby_vision_extract_pattern ~r/Dolby[\s.]?Vision/i

  # Audio normalizers
  @audio_space_digit_pattern ~r/\d\s\d/
  @audio_space_digit_capture ~r/(\d)\s(\d)/
  @audio_dtshd_ma_pattern ~r/DTS-HD\sMA/i
  @audio_dtshd_ma_capture ~r/(DTS-HD)\s(MA)/i
  @audio_channels_capture ~r/(\d+\.?\d*)/

  # --- Cleanup & Normalization Patterns ---
  @clean_filename_pattern ~r/[_.]/
  @clean_comparison_pattern ~r/[-_.':]/

  # Title cleaning
  @clean_empty_brackets ~r/[[(]\s*[])]/
  @clean_multi_space ~r/\s+/
  @clean_multi_dash ~r/[-_]{2,}/
  @clean_edge_separators ~r/^[-_\s]+|[-_\s]+$/

  # TV show patterns - defined as function to avoid module attribute issues
  defp tv_patterns do
    [
      # S01E01 or s01e01, with optional separator (S01 E01), and optional multi-episode S01E01-E03 or S01E01E03
      ~r/[. _-]S(\d{1,2})[. _-]?E(\d{1,2})(?:[. _-]?E(\d{1,2}))?/i,
      # 1x01
      ~r/[. _-](\d{1,2})x(\d{1,2})/i,
      # Season 1 Episode 1 (verbose)
      ~r/Season[. _-](\d{1,2})[. _-]Episode[. _-](\d{1,2})/i
    ]
  end

  # Pattern definitions are created in extraction_patterns/0 function
  # to avoid module attribute injection issues with function references

  @doc """
  Parses a file name or path and extracts media metadata using sequential pattern extraction.

  ## Options

  - `:standardize` - When `true`, converts codec/source variations to canonical forms (default: `false`)

  ## Examples

      iex> FileParser.V2.parse("Movie.Title.2020.1080p.BluRay.x264-GROUP.mkv")
      %{
        type: :movie,
        title: "Movie Title",
        year: 2020,
        quality: %{resolution: "1080p", source: "BluRay", codec: "x.264"},
        release_group: "GROUP",
        confidence: 0.95
      }

      iex> FileParser.V2.parse("Show.Name.S01E05.720p.WEB.mkv", standardize: true)
      %{
        type: :tv_show,
        title: "Show Name",
        season: 1,
        episodes: [5],
        quality: %{resolution: "720p", source: "WEB"},
        confidence: 0.9
      }
  """
@spec parse(String.t(), keyword()) :: parse_result()
  def parse(filename, opts \\ []) when is_binary(filename) do
    # Normalize filename (remove extension, convert dots/underscores to spaces)
    normalized = normalize_filename(filename)

    # Establish the Title Boundary BEFORE extraction
    boundary_pos = find_title_boundary(normalized)
    isolated_title_raw = byte_slice_before(normalized, boundary_pos)

    # Apply sequential extraction to the full normalized string
    {metadata, _remaining_text} = extract_all_patterns(normalized)

    # Clean the isolated title instead of relying on the remaining text!
    title = clean_title(isolated_title_raw)

    # Build result
    result = build_result(metadata, title, filename, opts)

    Logger.debug("FileParser.V2 parsed file",
      original: filename,
      type: result.type,
      title: result.title,
      year: result.year,
      season: result.season,
      episodes: result.episodes,
      confidence: result.confidence
    )

    result
  end

  @doc """
  Parses a full file path, using folder structure to enhance matching accuracy.

  When a file is in a structured TV library path like `/media/tv/{Show Name}/Season {XX}/`,
  the folder structure is used to identify the show. However, the confidence score
  reflects how well the filename agrees with the folder structure interpretation.

  ## Confidence Algorithm

  Confidence measures agreement between folder structure and filename signals:
  - High confidence: filename has episode markers, parsed as TV, title matches folder
  - Low confidence: filename looks like a movie, no episode markers, title differs

  This allows downstream code to filter or flag low-confidence results without
  special-case logic in the parser.

  ## Examples

      # Good match: filename agrees with folder structure
      iex> FileParser.V2.parse_with_path("/media/tv/One-Punch Man/Season 03/One-Punch.Man.S03E04.mkv")
      %{
        type: :tv_show,
        title: "One-Punch Man",
        season: 3,
        episodes: [4],
        confidence: 0.97   # High - all signals agree
      }

      # Poor match: filename looks like a movie in TV folder
      iex> FileParser.V2.parse_with_path("/media/tv/Bluey/Season 03/Playdate 2025 2160p.mkv")
      %{
        type: :tv_show,
        title: "Bluey",     # From folder
        season: 3,
        episodes: [],
        confidence: 0.07   # Very low - signals conflict
      }
  """
  @spec parse_with_path(String.t(), keyword()) :: parse_result()
  def parse_with_path(file_path, opts \\ []) when is_binary(file_path) do
    # First, parse the filename normally
    filename = Path.basename(file_path)
    filename_result = parse(filename, opts)

    # Try to extract folder structure info
    alias Mydia.Library.PathParser

    # First, check for TV show folder structure
    case PathParser.extract_from_path(file_path) do
      %{show_name: show_name, season: folder_season} ->
        # TV folder structure found (show/season folders detected)
        # Now try to get enhanced metadata (year, external IDs) from the show folder
        tv_folder_info = PathParser.extract_tv_show_from_path(file_path)

        # Use enhanced folder info if available, otherwise just use basic show_name
        folder_title = if tv_folder_info, do: tv_folder_info.title, else: show_name
        folder_year = if tv_folder_info, do: tv_folder_info.year, else: nil
        external_id = if tv_folder_info, do: tv_folder_info.external_id, else: nil
        external_provider = if tv_folder_info, do: tv_folder_info.external_provider, else: nil

        Logger.debug("Using TV folder structure for parsing",
          path: file_path,
          folder_show_name: folder_title,
          folder_season: folder_season,
          folder_year: folder_year,
          folder_external_id: external_id,
          folder_external_provider: external_provider,
          filename_title: filename_result.title,
          filename_season: filename_result.season,
          filename_type: filename_result.type
        )

        # Calculate confidence based on how well filename agrees with folder interpretation
        # Boost confidence if we have an external ID (very reliable)
        base_confidence =
          calculate_folder_enhanced_confidence(filename_result, folder_title, folder_season)

        confidence =
          if external_id != nil do
            # External ID provides very high confidence
            min(base_confidence + 0.20, 1.0)
          else
            base_confidence
          end

        # The folder structure indicates this is a TV show
        # Use folder's show name (authoritative) but keep episode info from filename
        %ParsedFileInfo{
          type: :tv_show,
          title: folder_title,
          # Prefer folder year, then filename year
          year: folder_year || filename_result.year,
          # Prefer folder season, but fall back to filename season if folder doesn't specify
          season: folder_season || filename_result.season,
          episodes: filename_result.episodes || [],
          quality: filename_result.quality,
          release_group: filename_result.release_group,
          confidence: confidence,
          original_filename: filename,
          external_id: external_id,
          external_provider: external_provider
        }
        |> SampleDetector.apply_detection(file_path)

      nil ->
        # No TV folder structure found - check for movie folder structure
        case PathParser.extract_movie_from_path(file_path) do
          %{title: folder_title} = movie_info ->
            # Movie folder structure found - prioritize folder metadata over filename
            Logger.debug("Using movie folder structure for parsing",
              path: file_path,
              folder_title: folder_title,
              folder_year: movie_info.year,
              folder_external_id: movie_info.external_id,
              folder_external_provider: movie_info.external_provider,
              filename_title: filename_result.title,
              filename_year: filename_result.year
            )

            # Calculate confidence based on folder metadata quality
            confidence = calculate_movie_folder_confidence(movie_info, filename_result)

            %ParsedFileInfo{
              type: :movie,
              # Prefer folder title as authoritative
              title: folder_title,
              # Prefer folder year, fall back to filename year
              year: movie_info.year || filename_result.year,
              season: nil,
              episodes: nil,
              quality: filename_result.quality,
              release_group: filename_result.release_group,
              confidence: confidence,
              original_filename: filename,
              external_id: movie_info.external_id,
              external_provider: movie_info.external_provider
            }
            |> SampleDetector.apply_detection(file_path)

          nil ->
            # No folder structure found - return filename-based result with sample detection
            SampleDetector.apply_detection(filename_result, file_path)
        end
    end
  end

  # Calculate confidence for movie folder-based parsing
  # Higher confidence when folder has external ID (very reliable)
  # Lower when only title/year extracted
  defp calculate_movie_folder_confidence(movie_info, filename_result) do
    base = 0.60

    # External ID is very reliable indicator
    external_id_bonus =
      if movie_info.external_id != nil do
        0.30
      else
        0.0
      end

    # Year in folder adds confidence
    year_bonus =
      if movie_info.year != nil do
        0.05
      else
        0.0
      end

    # Filename agreeing with folder adds small bonus
    title_agreement_bonus =
      if filename_result.title != nil do
        title_sim = simple_title_similarity(movie_info.title, filename_result.title)

        if title_sim >= 0.7 do
          0.05
        else
          0.0
        end
      else
        0.0
      end

    min(base + external_id_bonus + year_bonus + title_agreement_bonus, 1.0)
  end

  # Calculate confidence when folder structure is used.
  # Measures agreement between folder interpretation and filename signals.
  #
  # High confidence when:
  # - Filename has episode markers (S01E01, 1x01, etc.)
  # - Filename parsed as TV show
  # - Filename title similar to folder name
  # - Filename season matches folder season
  #
  # Low confidence when:
  # - No episode markers in filename
  # - Filename parsed as movie
  # - Filename title completely different from folder
  defp calculate_folder_enhanced_confidence(filename_result, show_name, folder_season) do
    # Start with moderate base - folder structure alone is not definitive
    base = 0.50

    # Factor 1: Does filename have episode markers? (Most important for TV)
    episode_factor =
      if filename_result.episodes != nil && filename_result.episodes != [] do
        0.20
      else
        # Missing episodes is suspicious for a file in a TV folder
        -0.15
      end

    # Factor 2: Was filename parsed as a TV show?
    type_factor =
      case filename_result.type do
        :tv_show -> 0.15
        # Filename thinks it's a movie - significant conflict
        :movie -> -0.20
        :unknown -> -0.05
      end

    # Factor 3: Do the seasons match?
    season_factor =
      cond do
        # No season in filename - neutral (common for some releases)
        filename_result.season == nil -> 0.0
        # Seasons match - good agreement
        filename_result.season == folder_season -> 0.10
        # Seasons conflict - concerning
        true -> -0.10
      end

    # Factor 4: Title similarity between folder and filename
    title_factor =
      if filename_result.title do
        similarity = simple_title_similarity(show_name, filename_result.title)

        cond do
          # Strong match (e.g., "One-Punch Man" vs "One Punch Man")
          similarity >= 0.8 -> 0.15
          # Moderate match
          similarity >= 0.5 -> 0.0
          # Weak match
          similarity >= 0.3 -> -0.10
          # Poor/no match (e.g., "Bluey" vs "Playdate")
          true -> -0.20
        end
      else
        0.0
      end

    # Factor 5: Quality info (minor positive signal)
    quality_factor =
      if filename_result.quality && filename_result.quality.resolution != nil do
        0.02
      else
        0.0
      end

    # Sum it all up and clamp to valid range
    confidence =
      base + episode_factor + type_factor + season_factor + title_factor + quality_factor

    min(max(confidence, 0.0), 1.0)
  end

  # Simple title similarity using Jaro distance after normalization
  defp simple_title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    norm1 = normalize_for_comparison(title1)
    norm2 = normalize_for_comparison(title2)

    cond do
      norm1 == norm2 -> 1.0
      String.contains?(norm1, norm2) || String.contains?(norm2, norm1) -> 0.85
      true -> String.jaro_distance(norm1, norm2)
    end
  end

  defp simple_title_similarity(_title1, _title2), do: 0.0

  # Normalize title for comparison: lowercase, remove punctuation, normalize whitespace
  defp normalize_for_comparison(title) do
    title
    |> String.downcase()
    |> String.replace(@clean_comparison_pattern, " ")
    |> String.replace(@clean_multi_space, " ")
    |> String.trim()
  end

  ## Sequential Extraction

  # Define extraction patterns as a function to avoid module attribute issues
  defp extraction_patterns do
    [
      # TV show pattern - must be first to identify TV shows before other patterns
      %{
        name: :tv_show,
        type: :tv_identifier,
        regex: :tv_patterns,
        handler: &extract_tv_info/3
      },
      # Year (primary) - parenthesized/bracketed years first (highest priority)
      %{
        name: :year,
        type: :metadata,
        regex: @year_pattern_primary,
        handler: &extract_year/3
      },
      # Quality markers - extract before release group to avoid partial matches
      %{
        name: :resolution,
        type: :quality,
        regex: @resolution_pattern,
        handler: &extract_resolution/3
      },
      %{
        name: :source,
        type: :quality,
        regex: @source_pattern,
        handler: &extract_source/3
      },
      %{
        name: :codec,
        type: :quality,
        regex: @codec_pattern,
        handler: &extract_codec/3
      },
      %{
        name: :hdr_format,
        type: :quality,
        regex: @hdr_pattern,
        handler: &extract_hdr/3
      },
      %{
        name: :audio,
        type: :quality,
        regex: @audio_pattern,
        handler: &extract_audio/3
      },
      # Noise patterns - remove but don't extract
      %{
        name: :bit_depth,
        type: :quality,
        regex: @bit_depth_pattern,
        handler: &extract_bit_depth/3
      },
      %{
        name: :encoder,
        type: :quality,
        regex: @encoder_pattern,
        handler: &extract_encoder/3
      },
      %{
        name: :audio_channels,
        type: :quality,
        regex: @audio_channels_pattern,
        handler: &extract_audio_channels/3
      },
      %{
        name: :vmaf_score,
        type: :quality,
        regex: @vmaf_pattern,
        handler: &extract_vmaf_score/3
      },
      %{
        name: :hdr_profile,
        type: :quality,
        regex: @hdr_profile_pattern,
        handler: &extract_hdr_profile/3
      },
      %{
        name: :bracket_contents,
        type: :noise,
        regex: @bracket_contents_pattern,
        handler: &extract_and_discard/3
      },
      %{
        name: :release_tags,
        type: :quality,
        regex: @extra_noise_pattern,
        handler: &extract_release_tags/3
      },
      %{
        name: :streaming_service,
        type: :quality,
        regex: @streaming_service_pattern,
        handler: &extract_streaming_service/3
      },
      %{
        name: :language,
        type: :quality,
        regex: @language_pattern,
        handler: &extract_language/3
      },
      %{
        name: :rating,
        type: :quality,
        regex: @rating_pattern,
        handler: &extract_rating/3
      },
      %{
        name: :runtime,
        type: :quality,
        regex: @runtime_pattern,
        handler: &extract_runtime/3
      },
      # Year (secondary) - standalone years (only if no year extracted yet)
      %{
        name: :year_secondary,
        type: :metadata_conditional,
        regex: @year_pattern_secondary,
        handler: &extract_year_conditional/3
      },
      # Release group - extract LAST to avoid conflicting with quality markers (DTS-HD, WEB-DL, AAC-LC)
      %{
        name: :release_group,
        type: :metadata,
        regex: @release_group_pattern,
        handler: &extract_release_group/3
      }
    ]
  end

  defp extract_all_patterns(text) do
    # Store original text in metadata for handlers that need position context
    initial_metadata = %{_original_text: text}

    # Reduce over all patterns, extracting and removing matches sequentially
    {metadata, remaining} =
      Enum.reduce(extraction_patterns(), {initial_metadata, text}, fn pattern,
        {metadata, remaining_text} ->
        extract_pattern(pattern, metadata, remaining_text)
      end)

    # Remove internal metadata before returning
    {Map.delete(metadata, :_original_text), remaining}
  end

  # Slice text using byte offsets from Regex.run(..., return: :index).
  # Regex returns byte positions, but String.slice expects character positions.
  # For multi-byte UTF-8 strings these diverge, so we use :binary.part which
  # operates on bytes directly.
  defp byte_slice(text, start, length), do: :binary.part(text, start, length)
  defp byte_slice_before(text, byte_pos), do: :binary.part(text, 0, byte_pos)

  defp byte_slice_after(text, byte_pos),
    do: :binary.part(text, byte_pos, byte_size(text) - byte_pos)

  defp extract_pattern(%{regex: :tv_patterns}, metadata, text) do
    # Special case: TV patterns use a list of regexes
    case match_tv_patterns(text) do
      {:ok, tv_metadata, match_start, match_length} ->
        # Remove the matched TV pattern from text and everything after it until a quality marker
        before = byte_slice_before(text, match_start)
        after_match = byte_slice_after(text, match_start + match_length)

        # Discard text between episode marker and first quality marker to remove episode titles
        after_match_cleaned = discard_until_quality_marker(after_match)

        new_text = before <> " " <> after_match_cleaned

        # Merge TV metadata into main metadata
        {Map.merge(metadata, tv_metadata), new_text}

      :error ->
        {metadata, text}
    end
  end

  defp extract_pattern(pattern, metadata, text) do
    # Skip conditional patterns if the condition is not met
    if pattern.type == :metadata_conditional do
      # For conditional year extraction, only proceed if no year was extracted yet
      if Map.has_key?(metadata, :year) do
        {metadata, text}
      else
        do_extract_pattern(pattern, metadata, text, :year)
      end
    else
      do_extract_pattern(pattern, metadata, text, nil)
    end
  end

  defp do_extract_pattern(pattern, metadata, text, target_key) do
    case Regex.run(pattern.regex, text, return: :index) do
      nil ->
        # No match, continue with same metadata and text
        {metadata, text}

      [{start, length} | _captures] ->
        # Extract the matched portion
        match = byte_slice(text, start, length)

        # Call the handler to extract value
        value = pattern.handler.(match, text, metadata)

        # Remove matched portion from text (replace with space to preserve word boundaries)
        new_text =
          byte_slice_before(text, start) <>
            " " <> byte_slice_after(text, start + length)

        # Update metadata if value is not nil (noise patterns return nil)
        new_metadata =
          if value != nil do
            final_key = target_key || pattern.name

            case pattern.type do
              :quality ->
                # Update quality map (will be converted to struct in build_result)
                quality = Map.get(metadata, :quality, %{})
                Map.put(metadata, :quality, Map.put(quality, pattern.name, value))

              :metadata_conditional ->
                # Add to metadata with target key
                Map.put(metadata, final_key, value)

              _ ->
                # Add to metadata directly
                Map.put(metadata, pattern.name, value)
            end
          else
            metadata
          end

        {new_metadata, new_text}
    end
  end

  ## Pattern Handlers

  # TV show pattern matcher
  defp match_tv_patterns(text) do
    Enum.reduce_while(tv_patterns(), :error, fn pattern, _acc ->
      case Regex.run(pattern, text, return: :index) do
        nil ->
          {:cont, :error}

        [{match_start, match_length} | captures] ->
          # Extract season and episode numbers from captures
          {season, episodes} = parse_tv_captures(text, captures)

          tv_metadata = %{
            type: :tv_show,
            season: season,
            episodes: episodes
          }

          {:halt, {:ok, tv_metadata, match_start, match_length}}
      end
    end)
  end

  defp parse_tv_captures(text, captures) do
    numbers =
      captures
      |> Enum.reject(&(&1 == {-1, 0}))
      |> Enum.map(fn {start, length} ->
        text
        |> byte_slice(start, length)
        |> Integer.parse()
      end)
      |> Enum.map(fn
        {num, ""} -> num
        {num, _rest} -> num
        :error -> nil
      end)

    case numbers do
      [season, episode] when is_integer(season) and is_integer(episode) ->
        {season, [episode]}

      [season, episode1, episode2]
      when is_integer(season) and is_integer(episode1) and is_integer(episode2) ->
        # Multi-episode (e.g., S01E01-E03)
        {season, Enum.to_list(episode1..episode2)}

      _ ->
        {nil, []}
    end
  end

  # Discard text until we hit a quality marker to remove episode titles, but preserve years
  defp discard_until_quality_marker(text) do
    # First, check if there's a year in parentheses/brackets in the text
    year_match =
      case Regex.run(@year_pattern_primary, text, return: :index) do
        [{start, length} | _] -> {start, length}
        nil -> nil
      end

    # Look for the first occurrence of any quality marker pattern
    # Note: @release_group_pattern is intentionally excluded here because it should be
    # extracted last, not used as a marker for discarding episode titles
    quality_patterns = [
      @resolution_pattern,
      @source_pattern,
      @codec_pattern,
      @hdr_pattern,
      @audio_pattern,
      @bit_depth_pattern
    ]

    # Find the earliest match position among all quality patterns
    earliest_match =
      quality_patterns
      |> Enum.map(fn pattern ->
        case Regex.run(pattern, text, return: :index) do
          [{start, _length} | _] -> start
          nil -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    case {year_match, earliest_match} do
      {nil, nil} ->
        # No year, no quality marker - discard everything
        ""

      {{year_start, year_length}, nil} ->
        # Year found but no quality marker - preserve only the year
        byte_slice(text, year_start, year_length)

      {nil, position} ->
        # No year, but quality marker found - keep from quality marker onward
        byte_slice_after(text, position)

      {{year_start, year_length}, position} ->
        # Both year and quality marker found - preserve year and everything from quality marker
        year_text = byte_slice(text, year_start, year_length)
        quality_text = byte_slice_after(text, position)
        year_text <> " " <> quality_text
    end
  end

  def extract_tv_info(_match, _text, _metadata) do
    # TV info is handled specially in match_tv_patterns
    nil
  end

  def extract_year(match, _text, _metadata) do
    # Extract year from match (can be in parentheses, brackets, dots, or standalone)
    case Regex.run(@year_extract_pattern, match) do
      [_, year_str] -> String.to_integer(year_str)
      [year_str] -> String.to_integer(year_str)
      _ -> nil
    end
  end

  def extract_year_conditional(match, _text, _metadata) do
    # Same as extract_year, but only called if no year was extracted yet
    extract_year(match, nil, nil)
  end

  def extract_release_group(match, _text, _metadata) do
    # Extract group name from hyphen-prefixed pattern (with optional site tag)
    case Regex.run(@release_group_pattern, match) do
      [_, group] -> group
      _ -> nil
    end
  end

  def extract_resolution(match, _text, _metadata) do
    case Regex.run(@resolution_extract_pattern, match) do
      [_, resolution] -> String.downcase(resolution)
      [resolution] -> String.downcase(resolution)
      nil -> String.downcase(match)
    end
  end

  def extract_source(match, _text, metadata) do
    # For standalone "WEB", validate it's not part of the title (like "Madame.Web")
    # by checking if it appears after quality markers in the original text
    if String.upcase(match) == "WEB" do
      # Use original text from metadata for position checking
      original_text = Map.get(metadata, :_original_text, "")
      validate_web_source(original_text)
    else
      match
    end
  end

  # Validates WEB is a source and not part of the title by checking position
  # relative to quality markers (year, resolution, episode markers)
defp validate_web_source(text) do
    # Find the position of WEB in the text
    web_pos = find_word_position(text, @web_word_pattern)

    # Find positions of quality markers that would indicate WEB is after them
    year_pos = find_word_position(text, @year_pattern_secondary)
    resolution_pos = find_word_position(text, @resolution_pattern)
    episode_pos = find_word_position(text, @episode_pattern)

    # WEB is valid if it appears after any quality marker
    quality_marker_pos =
      [year_pos, resolution_pos, episode_pos]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    cond do
      # No quality markers found - WEB could be part of title, reject it
      is_nil(quality_marker_pos) -> nil
      # WEB appears after quality marker - it's a source
      web_pos > quality_marker_pos -> "WEB"
      # WEB appears before quality markers - likely part of title
      true -> nil
    end
  end

  defp find_word_position(text, pattern) do
    case Regex.run(pattern, text, return: :index) do
      [{pos, _} | _] -> pos
      _ -> nil
    end
  end

  def extract_codec(match, _text, _metadata) do
    # Normalize codec (x 264 → x.264, h 264 → h.264)
    if String.match?(match, @codec_space_pattern) do
      String.replace(match, " ", ".")
    else
      match
    end
  end

  def extract_hdr(match, _text, _metadata) do
    # Normalize HDR formats
    cleaned_match = String.trim(match)
    upcase_match = String.upcase(cleaned_match)

    cond do
      String.contains?(upcase_match, "HDR10+") ||
        String.contains?(upcase_match, "HDR10 ") ->
        "HDR10+"
      String.match?(cleaned_match, @dolby_vision_extract_pattern) ->
        "DolbyVision"
      upcase_match in ["DOVI", "DV"] ->
        "DolbyVision"

        true ->
        cleaned_match
    end
  end

  def extract_audio(match, _text, _metadata) do
    # Normalize audio codec
    normalized =
      if String.match?(match, @audio_space_digit_pattern) do
        String.replace(match, @audio_space_digit_capture, "\\1.\\2")
      else
        match
      end

    # Normalize DTS-HD MA → DTS-HD.MA
    if String.match?(normalized, @audio_dtshd_ma_pattern) do
      String.replace(normalized, @audio_dtshd_ma_capture, "\\1.\\2")
    else
      normalized
    end
  end

  # Additional quality metadata extractors for feature parity with V1
  def extract_bit_depth(match, _text, _metadata) do
    case Regex.run(~r/(8|10|12)/, match) do
      [_, depth] -> "#{depth}bit"
      _ -> nil
    end
  end

  def extract_encoder(match, _text, _metadata) do
    case Regex.run(~r/(NVENC|QSV|AMF|VCE|VideoToolbox)/, match) do
      [_, encoder] -> encoder
      _ -> nil
    end
  end

  def extract_audio_channels(match, _text, _metadata) do
    # Normalize "5 1" to "5.1"
    String.replace(match, " ", ".")
  end

  def extract_vmaf_score(match, _text, _metadata) do
    match
  end

  def extract_hdr_profile(match, _text, _metadata) do
    match
  end

  def extract_release_tags(match, _text, _metadata) do
    match
  end

  def extract_streaming_service(match, _text, _metadata) do
    match
  end

  def extract_language(match, _text, _metadata) do
    match
  end

  def extract_rating(match, _text, _metadata) do
    match
  end

  def extract_runtime(match, _text, _metadata) do
    match
  end

  def extract_and_discard(_match, _text, _metadata) do
    # Noise patterns are removed but not extracted
    nil
  end

  ## Result Building

  defp build_result(metadata, title, original_filename, opts) do
    # Extract fields with defaults (no Map.get - direct access with defaults)
    type = metadata[:type] || :unknown
    year = metadata[:year]
    season = metadata[:season]
    episodes = metadata[:episodes]
    quality_map = metadata[:quality] || %{}
    release_group = metadata[:release_group]

    # Convert quality map to struct
    quality = Quality.new(quality_map)

    # Determine media type if not already set
    type =
      cond do
        type == :tv_show -> :tv_show
        season != nil || episodes != nil -> :tv_show
        true -> infer_media_type(title, year, quality)
      end

    # Calculate confidence
    confidence =
      case type do
        :tv_show -> calculate_tv_confidence(title, season, episodes, quality)
        :movie -> calculate_movie_confidence(title, year, quality)
        :unknown -> 0.0
      end

    # Apply standardization if requested
    quality =
      if Keyword.get(opts, :standardize, false) do
        standardize_quality(quality)
      else
        quality
      end

    # Return a struct instead of a plain map
    %ParsedFileInfo{
      type: type,
      title: title,
      year: year,
      season: season,
      episodes: episodes,
      quality: quality,
      release_group: release_group,
      confidence: confidence,
      original_filename: original_filename
    }
  end

  defp infer_media_type(title, year, quality) do
    # Require at least some meaningful attributes to classify as movie
    has_year = year != nil
    has_quality = !Quality.empty?(quality) && (quality.resolution != nil || quality.source != nil)
    has_good_title = title != nil && String.length(title) > 3

    cond do
      # Require at least year OR quality to classify as movie
      has_year || has_quality -> :movie
      # Files with no metadata but a title should be unknown (too ambiguous)
      has_good_title -> :unknown
      true -> :unknown
    end
  end

  ## Helper Functions

defp normalize_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(@clean_filename_pattern, " ")
    |> String.trim()
  end

  defp clean_title(text) do
    # Known quality markers that might slip through (case-insensitive)
    quality_markers =
      ~w(uhd hdr hdr10 hdr10+ dolbyvision dovi dv remux atmos dts dd ddp eac3 truehd aac ac3 hevc avc xvid divx vp9 av1 nvenc web bluray bdrip brrip webrip webdl hdtv dvd dvdrip dvdscr proper repack internal limited unrated extended theatrical amzn nf atvp hybrid)

    text
    # Remove empty brackets/parentheses that remain after extraction
    |> String.replace(@clean_empty_brackets, " ")
    # Collapse multiple spaces
    |> String.replace(@clean_multi_space, " ")
    # Remove multiple dashes/underscores
    |> String.replace(@clean_multi_dash, " ")
    # Remove leading/trailing separators
    |> String.replace(@clean_edge_separators, "")
    |> String.trim()
    # Split into words and clean up
    |> String.split(@clean_multi_space)
    |> Enum.reject(&(&1 in ["", "-", "_", "+"]))
    # Filter out quality markers (case-insensitive) but preserve numbers that are part of titles
    |> Enum.reject(fn word ->
      String.downcase(word) in quality_markers
      end)
    |> Enum.map(&smart_capitalize/1)
    |> Enum.join(" ")
  end

# Finds the exact byte index where the title ends and the metadata/garbage begins
  defp find_title_boundary(text) do
    # These are definitive markers that almost never appear IN a title,
    # but always appear immediately AFTER a title.
    markers = [
      @year_pattern_primary,          # e.g., [2008] or (1999)
      @resolution_pattern,            # e.g., 1080p, 4K, UHD
      @episode_pattern                # e.g., S01E01
    ]

    markers
    |> Enum.map(fn pattern ->
      case Regex.run(pattern, text, return: :index) do
        [{pos, _len} | _] -> pos
        nil -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    # If no markers are found, assume the whole string is the title
    |> Enum.min(fn -> byte_size(text) end)
  end

  # Smart capitalization that preserves intentional mixed case but normalizes random mixed case
  defp smart_capitalize(word) do
    cond do
      # Empty or very short words - just capitalize
      String.length(word) < 2 ->
        String.capitalize(word)

      # All lowercase - capitalize
      word == String.downcase(word) ->
        String.capitalize(word)

      # Contains hyphen - preserve (e.g., "One-Punch")
      String.contains?(word, "-") ->
        word

      # Already properly capitalized (first letter uppercase, rest lowercase) - preserve
      word == String.capitalize(word) ->
        word

      # All uppercase - normalize to capitalized (e.g., "MOVIE" -> "Movie")
      word == String.upcase(word) ->
        String.capitalize(word)

      # Mixed case that doesn't follow standard capitalization - normalize
      true ->
        String.capitalize(word)
    end
  end

  defp calculate_movie_confidence(title, year, quality) do
    has_year = year != nil
    has_quality = !Quality.empty?(quality) && (quality.resolution != nil || quality.source != nil)
    has_good_title = title != nil && String.length(title) > 3

    base_confidence =
      cond do
        !has_good_title && !has_year && !has_quality -> 0.0
        !has_year && !has_quality -> 0.2
        true -> 0.5
      end

    confidence =
      base_confidence
      |> add_confidence(has_good_title, 0.2)
      |> add_confidence(year != nil, 0.15)
      |> add_confidence(quality.resolution != nil, 0.1)
      |> add_confidence(quality.source != nil, 0.05)

    min(confidence, 1.0)
  end

  defp calculate_tv_confidence(title, season, episodes, quality) do
    base_confidence = 0.6

    confidence =
      base_confidence
      |> add_confidence(title != nil && String.length(title) > 0, 0.15)
      |> add_confidence(season != nil, 0.1)
      |> add_confidence(episodes != nil && length(episodes) > 0, 0.1)
      |> add_confidence(quality.resolution != nil, 0.05)

    min(confidence, 1.0)
  end

  defp add_confidence(current, true, amount), do: current + amount
  defp add_confidence(current, false, _amount), do: current

  ## Standardization Layer (Phase 3)

  # Standardizes quality metadata to canonical forms.
  defp standardize_quality(%Quality{} = quality) do
    %Quality{
      audio: standardize_audio(quality.audio),
      codec: standardize_codec(quality.codec),
      source: standardize_source(quality.source),
      resolution: standardize_resolution(quality.resolution),
      hdr_format: standardize_hdr(quality.hdr_format)
    }
  end

  # Audio Codec Standardization
  defp standardize_audio(nil), do: nil

  defp standardize_audio(audio) do
    normalized = String.downcase(audio)

    cond do
      # Dolby Digital Plus (E-AC3) - must check EAC3 and AC3 separately from DDP/DD to avoid matching the "3"
      normalized == "eac3" ->
        "Dolby Digital Plus"
      String.starts_with?(normalized, "ddp") ->
        extract_channels(audio, "Dolby Digital Plus")

      # Dolby Digital (AC3) - must check AC3 separately from DD to avoid matching the "3"
      normalized == "ac3" ->
        "Dolby Digital"
      String.starts_with?(normalized, "dd") ->
        extract_channels(audio, "Dolby Digital")

      # DTS variants
      String.contains?(normalized, "dts-hd") && String.contains?(normalized, "ma") ->
        "DTS-HD Master Audio"
      String.contains?(normalized, "dts-hd") ->
        "DTS-HD High Resolution Audio"
      normalized == "dts-x" ->
        "DTS:X"
      normalized == "dts" ->
        "DTS"

      # Dolby TrueHD
      String.contains?(normalized, "truehd") ->
        extract_channels(audio, "Dolby TrueHD")

      # Dolby Atmos
      normalized == "atmos" ->
        "Dolby Atmos"

      # AAC variants
      String.starts_with?(normalized, "aac-lc") ->
        "AAC-LC"
      String.starts_with?(normalized, "aac") ->
        extract_channels(audio, "AAC")

      # Unknown - return as-is
      true ->
        audio
    end
  end

  defp extract_channels(audio, base_name) do
    case Regex.run(@audio_channels_capture, audio) do
      [_, channels] -> "#{base_name} #{channels}"
      _ -> base_name
    end
  end

  # Video Codec Standardization
  defp standardize_codec(nil), do: nil

  defp standardize_codec(codec) do
    normalized = String.downcase(codec)

    cond do
      # H.265/HEVC
      normalized in ["hevc", "h265", "h.265", "x265", "x.265"] ->
        "H.265/HEVC"

      # H.264/AVC
      normalized in ["avc", "h264", "h.264", "x264", "x.264"] ->
        "H.264/AVC"

      # Legacy codecs
      normalized == "xvid" ->
        "XviD"
      normalized == "divx" ->
        "DivX"

      # Modern codecs
      normalized == "vp9" ->
        "VP9"
      normalized == "av1" ->
        "AV1"

      # Hardware encoders
      normalized == "nvenc" ->
        "NVENC"

      # Unknown - return as-is
      true ->
        codec
    end
  end

  # Source Standardization
  defp standardize_source(nil), do: nil

  defp standardize_source(source) do
    normalized = String.downcase(source)

    cond do
      # Blu-ray variants
      normalized in ["bluray", "bdrip", "brrip"] ->
        "Blu-ray"

      # REMUX
      normalized == "remux" ->
        "Remux"

      # WEB variants (keep distinct)
      normalized == "web-dl" ->
        "WEB-DL"

      String.match?(normalized, ~r/^webrip$/i) ->
        "WEBRip"

      String.match?(normalized, ~r/^web$/i) ->
        "WEB"

      # HDTV
      normalized == "hdtv" ->
        "HDTV"

      # DVD variants
      normalized in ["dvd", "dvdrip", "dvdscr"] ->
        "DVD"

      # Unknown - return as-is
      true ->
        source
    end
  end

  # Resolution Standardization
  defp standardize_resolution(nil), do: nil

  defp standardize_resolution(resolution) do
    normalized = String.downcase(resolution)

    cond do
      # 4K/2160p
      normalized in ["2160p", "4k", "uhd"] ->
        "2160p (4K)"

        # 1080p
      normalized == "1080p" ->
        "1080p (Full HD)"

      # 720p
      normalized == "720p" ->
        "720p (HD)"

      # 8K
      normalized in ["4320p", "8k"] ->
        "4320p (8K)"

      # 576p/480p (SD)
      normalized in ["576p", "480p"] ->
        "#{resolution} (SD)"

      # Unknown - return as-is
      true ->
        resolution
    end
  end

  # HDR Format Standardization
  defp standardize_hdr(nil), do: nil

  defp standardize_hdr(hdr) do
    normalized = String.downcase(hdr)

    cond do
      # HDR10+
      String.contains?(normalized, "hdr10+") ->
        "HDR10+"

      # HDR10
      normalized == "hdr10" ->
        "HDR10"

      # Dolby Vision
      normalized in ["dolbyvision", "dovi"] ->
        "Dolby Vision"

      # Generic HDR
      normalized == "hdr" ->
        "HDR"

      # Unknown - return as-is
      true ->
        hdr
    end
  end
end
