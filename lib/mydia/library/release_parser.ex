defmodule Mydia.Library.ReleaseParser do
  @moduledoc """
  Public facade for the V3 release-name parser.

  The production parser used by `Mydia.Library`, `Mydia.Jobs.MediaImport`,
  `Mydia.Jobs.LibraryScanner`, `Mydia.Library.MetadataMatcher`, and
  `MydiaWeb.SearchLive.Index`. Returns `%ParsedFileInfo{}` with two
  optional fields beyond the historical V2 surface
  (`field_confidence`, `engine_flags`) carrying parser confidence and
  sideband signals.

  ## Pipeline

  1. `Tokenizer.tokenize/1` + `Tokenizer.anchor_positions/1` (byte-safe)
  2. `Classifier.classify/2`
  3. `Resolver.resolve/3`
  4. `QualityExtractor.extract/2`
  5. `Title` + `Type` inference (from the resolver result)
  6. Build `%ParsedFileInfo{}` with confidence

  Known corpus gaps and the clusters V3 deliberately does not handle are
  catalogued in `test/mydia/library/release_parser/CORPUS_FAILURES.md`.
  """

  require Logger

  alias Mydia.Library.PathParser
  alias Mydia.Library.ReleaseParser.Classifier
  alias Mydia.Library.ReleaseParser.QualityExtractor
  alias Mydia.Library.ReleaseParser.Resolver
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.ReleaseParser.Tokenizer
  alias Mydia.Library.SampleDetector
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality
  alias Mydia.Library.Text

  @type parse_opts :: [
          standardize: boolean(),
          target: TargetContext.t() | nil,
          folder_context: map() | nil
        ]

  @doc """
  Parse a release-name string into a `%ParsedFileInfo{}`.

  Equivalent to `parse/2` with default opts.
  """
  @spec parse(String.t()) :: ParsedFileInfo.t()
  def parse(filename), do: parse(filename, [])

  @doc """
  Parse a release-name string with options.

  ## Options

  - `:standardize` — when `true`, codec / source / audio / resolution
    values are returned in canonical form (`"H.264/AVC"`, `"Blu-ray"`,
    `"Dolby Digital Plus 5.1"`, `"2160p (4K)"`). Defaults to `false`
    matching V2's behavior.
  - `:target` — a `%TargetContext{}` to lock `type` / `title` / `year`
    when the caller already knows which media item this file belongs
    to. Adds `binding_confidence` to the resulting struct's
    `field_confidence` map and may set `:binding_suspect` /
    `:parsed_title_unbound` / `:season_out_of_range` flags in
    `engine_flags`.
  - `:folder_context` — folder-derived priors (title / year / season
    / external IDs) merged into the result. Provided by
    `parse_with_path/2`; callers usually don't pass this directly.
  """
  @spec parse(String.t(), parse_opts()) :: ParsedFileInfo.t()
  def parse(filename, opts) when is_binary(filename) and is_list(opts) do
    target = Keyword.get(opts, :target)
    folder_context = Keyword.get(opts, :folder_context)

    # V2 calls `Path.basename/1` on the input inside its
    # `normalize_filename/1`. Match that — callers occasionally pass a
    # full path even to `parse/2`.
    basename = Path.basename(filename)

    result =
      basename
      |> tokenize_classify_resolve(target)
      |> build_parsed_file_info(filename, opts)
      |> maybe_merge_folder_context(folder_context)

    Logger.debug("ReleaseParser parsed file",
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
  Parse a full file path using folder structure to enhance matching
  accuracy.

  Runs `PathParser.extract_from_path/1` (TV structure) or
  `PathParser.extract_movie_from_path/1` (movie structure) **once**,
  calls `parse/2` on `Path.basename(file_path)`, and applies
  `SampleDetector.apply_detection/2` **once** at the outer layer.
  """
  @spec parse_with_path(String.t(), parse_opts()) :: ParsedFileInfo.t()
  def parse_with_path(file_path, opts \\ []) when is_binary(file_path) do
    filename = Path.basename(file_path)
    filename_result = parse(filename, opts)

    cond do
      tv = PathParser.extract_from_path(file_path) ->
        tv_folder_info = PathParser.extract_tv_show_from_path(file_path)
        merge_tv_folder(filename_result, filename, file_path, tv, tv_folder_info)

      movie = PathParser.extract_movie_from_path(file_path) ->
        merge_movie_folder(filename_result, filename, file_path, movie)

      true ->
        SampleDetector.apply_detection(filename_result, file_path)
    end
  end

  # ---- Internals ----

  defp tokenize_classify_resolve(filename, target) do
    # Pre-pass: detect a trailing release-group separator (`-GROUP`)
    # and rewrite the dash to a space so the tokenizer splits it
    # cleanly. The dash before a trailing group has no semantic meaning
    # we want to preserve — it just makes the codec/quality token
    # downstream attach to the group name.
    {prepared, detected_group} = strip_trailing_release_group(filename)

    tokens = Tokenizer.tokenize(prepared)
    anchors = Tokenizer.anchor_positions(prepared)
    classified = Classifier.classify(tokens, anchors)
    resolver_result = Resolver.resolve(classified, target)

    # Pre-pass detection wins over vocab matches: the trailing
    # `-GROUP` is more authoritative than a token that happens to be
    # in the release-groups vocabulary (which often appears as a site
    # tag in trailing brackets, e.g. `[rarbg]`).
    final_group = detected_group || resolver_result.release_group

    Map.put(resolver_result, :release_group, final_group)
  end

  # V2's release-group regex: a hyphen/dot prefix or double-space
  # prefix, then one or two `[A-Z0-9]+` groups, optionally followed by
  # a bracket site tag, optionally followed by whitespace and the end.
  @release_group_re ~r/(?:[-.]|\s{2,})([A-Z0-9]+(?:[.\s][A-Z0-9]+)?)(?:\[[^\]]+\])?\s*$/i

  # Detect a trailing release-group separator (`-GROUP` or `. GROUP`)
  # and, when present, rewrite the separator to a space so the
  # tokenizer cleanly separates the group from the preceding token.
  #
  # V2 normalizes `.` and `_` to spaces before running the regex; we
  # replicate that for matching only (the rewritten input keeps the
  # original separators except for the matched span).
  defp strip_trailing_release_group(filename) do
    stripped_for_match = Tokenizer.drop_extension(filename)
    normalized = String.replace(stripped_for_match, ~r/[._]/, " ")

    case Regex.run(@release_group_re, normalized, return: :index) do
      [{full_start, _full_len}, {g_start, g_len}] ->
        group_name = :binary.part(normalized, g_start, g_len)
        # Check if the preceding token forms a known compound (e.g.
        # `AAC-LC`, `DTS-HD`) — if so, leave the dash intact.
        compound? = forms_known_compound?(stripped_for_match, full_start, group_name)

        if compound? do
          {filename, nil}
        else
          case sanitize_release_group(group_name) do
            nil ->
              {filename, nil}

            group ->
              rewritten = rewrite_trailing_separator(filename, normalized)
              {rewritten, group}
          end
        end

      _ ->
        {filename, nil}
    end
  end

  # When the captured "group" is actually a known compound suffix
  # (e.g. `AAC-LC`, `DTS-HD`, `WEB-DL`, `DTS-X`), don't treat it as a
  # release group.
  @known_compound_suffixes MapSet.new(["LC", "HD", "DL", "RIP", "X", "MA", "265", "264"])

  defp forms_known_compound?(_stripped, _full_start, group_name) do
    String.upcase(group_name) in @known_compound_suffixes
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
                            hevc avc xvid divx vp9 av1 nvenc opus flac mp3
                            x264 x265 h264 h265
                            proper repack internal limited unrated extended theatrical hybrid
                            amzn nf atvp dsnp hmax hulu pmtp pcok stan
                            4k 8k uhd 720p 1080p 2160p 480p 540p 576p 1440p 4320p
                            ddp5 ddp7 dd5 dd7 ddp51 ddp71 dd51 dd71 ddp20 dd20
                            aac20 aac51
                          ))

  # Token forms that the trailing-group regex sometimes captures (e.g.
  # `1080p.AAC` or `DDP5.1`). These should be rejected.
  @combined_marker_re ~r/^\d{3,4}[pPiIkK]?\.[A-Z0-9]+$/i
  @ddp_dd_channel_re ~r/^DD[P]?\d+(?:\.\d+)?$/i
  @dotted_codec_re ~r/^(?:[HX]\.?\d{3}|HEVC|AVC)$/i
  @contains_resolution_re ~r/\b(?:480p|540p|576p|720p|1080p|1440p|2160p|4320p|4K|8K|UHD)\b/i
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

  defp build_parsed_file_info(resolver_result, filename, opts) do
    quality = QualityExtractor.extract(resolver_result, opts)

    title = resolver_result.title
    type = resolver_result.type
    year = resolver_result.year
    season = resolver_result.season
    episodes = normalize_episodes(resolver_result.episodes)
    absolute_episode = resolver_result.absolute_episode
    release_group = resolver_result.release_group

    # Type inference: episode marker → tv_show; else use the resolver
    # type, with a fallback to V2-style infer_media_type for the
    # title/year/quality cases.
    type =
      cond do
        type == :tv_show -> :tv_show
        season != nil or (episodes != nil and episodes != []) -> :tv_show
        true -> infer_media_type(type, title, year, quality)
      end

    confidence =
      case type do
        :tv_show -> calculate_tv_confidence(title, season, episodes, quality)
        :movie -> calculate_movie_confidence(title, year, quality)
        :unknown -> 0.0
      end

    field_confidence = maybe_add_binding_confidence(resolver_result)

    %ParsedFileInfo{
      type: type,
      title: title,
      year: year,
      season: season,
      episodes: episodes,
      absolute_episode: absolute_episode,
      quality: quality,
      release_group: release_group,
      confidence: confidence,
      original_filename: filename,
      field_confidence: nilify(field_confidence),
      engine_flags: resolver_result.engine_flags
    }
  end

  defp normalize_episodes(nil), do: nil
  defp normalize_episodes([]), do: nil
  defp normalize_episodes(list) when is_list(list), do: list

  defp maybe_add_binding_confidence(%{field_confidence: fc, binding_confidence: nil}), do: fc

  defp maybe_add_binding_confidence(%{field_confidence: fc, binding_confidence: bc}) do
    Map.put(fc || %{}, :binding, bc)
  end

  defp nilify(nil), do: nil
  defp nilify(m) when map_size(m) == 0, do: nil
  defp nilify(m), do: m

  defp infer_media_type(:movie, _title, _year, _quality), do: :movie
  defp infer_media_type(:tv_show, _title, _year, _quality), do: :tv_show

  defp infer_media_type(_, title, year, quality) do
    has_year = year != nil
    has_quality = !Quality.empty?(quality) && (quality.resolution != nil || quality.source != nil)
    has_good_title = title != nil && byte_size(title) > 3

    cond do
      has_year or has_quality -> :movie
      has_good_title -> :unknown
      true -> :unknown
    end
  end

  defp calculate_tv_confidence(title, season, episodes, quality) do
    base = 0.6

    base
    |> add(title != nil and byte_size(title) > 0, 0.15)
    |> add(season != nil, 0.1)
    |> add(episodes != nil and episodes != [], 0.1)
    |> add(quality.resolution != nil, 0.05)
    |> min_clamp(1.0)
  end

  defp calculate_movie_confidence(title, year, quality) do
    has_year = year != nil

    has_quality =
      !Quality.empty?(quality) and (quality.resolution != nil or quality.source != nil)

    has_good_title = title != nil and byte_size(title) > 3

    base =
      cond do
        not has_good_title and not has_year and not has_quality -> 0.0
        not has_year and not has_quality -> 0.2
        true -> 0.5
      end

    base
    |> add(has_good_title, 0.2)
    |> add(year != nil, 0.15)
    |> add(quality.resolution != nil, 0.1)
    |> add(quality.source != nil, 0.05)
    |> min_clamp(1.0)
  end

  defp add(current, true, amount), do: current + amount
  defp add(current, false, _amount), do: current

  defp min_clamp(value, ceiling), do: min(value, ceiling)

  # ---- parse/2 folder-context merging (called from parse_with_path/2) ----

  defp maybe_merge_folder_context(result, nil), do: result

  defp maybe_merge_folder_context(%ParsedFileInfo{} = result, %{} = context) do
    %ParsedFileInfo{
      result
      | title: context[:title] || result.title,
        year: context[:year] || result.year,
        season: context[:season] || result.season,
        external_id: context[:external_id] || result.external_id,
        external_provider: context[:external_provider] || result.external_provider
    }
  end

  # ---- parse_with_path/2 helpers ----

  defp merge_tv_folder(filename_result, filename, file_path, tv, tv_folder_info) do
    folder_title = if tv_folder_info, do: tv_folder_info.title, else: tv.show_name
    folder_year = if tv_folder_info, do: tv_folder_info.year, else: nil
    external_id = if tv_folder_info, do: tv_folder_info.external_id, else: nil
    external_provider = if tv_folder_info, do: tv_folder_info.external_provider, else: nil

    base_confidence =
      folder_enhanced_tv_confidence(filename_result, folder_title, tv.season)

    confidence =
      if external_id != nil do
        min(base_confidence + 0.20, 1.0)
      else
        base_confidence
      end

    %ParsedFileInfo{
      type: :tv_show,
      title: folder_title,
      year: folder_year || filename_result.year,
      season: tv.season || filename_result.season,
      episodes: filename_result.episodes || [],
      quality: filename_result.quality,
      release_group: filename_result.release_group,
      confidence: confidence,
      original_filename: filename,
      external_id: external_id,
      external_provider: external_provider,
      field_confidence: filename_result.field_confidence,
      engine_flags: filename_result.engine_flags
    }
    |> SampleDetector.apply_detection(file_path)
  end

  defp merge_movie_folder(filename_result, filename, file_path, movie_info) do
    confidence = movie_folder_confidence(movie_info, filename_result)

    %ParsedFileInfo{
      type: :movie,
      title: movie_info.title,
      year: movie_info.year || filename_result.year,
      season: nil,
      episodes: nil,
      quality: filename_result.quality,
      release_group: filename_result.release_group,
      confidence: confidence,
      original_filename: filename,
      external_id: movie_info.external_id,
      external_provider: movie_info.external_provider,
      field_confidence: filename_result.field_confidence,
      engine_flags: filename_result.engine_flags
    }
    |> SampleDetector.apply_detection(file_path)
  end

  # Ports V2's `calculate_folder_enhanced_confidence/3` byte-for-byte.
  defp folder_enhanced_tv_confidence(filename_result, show_name, folder_season) do
    base = 0.50

    episode_factor =
      if filename_result.episodes != nil and filename_result.episodes != [] do
        0.20
      else
        -0.15
      end

    type_factor =
      case filename_result.type do
        :tv_show -> 0.15
        :movie -> -0.20
        :unknown -> -0.05
      end

    season_factor =
      cond do
        filename_result.season == nil -> 0.0
        filename_result.season == folder_season -> 0.10
        true -> -0.10
      end

    title_factor =
      if filename_result.title do
        similarity = Text.title_similarity(show_name, filename_result.title)

        cond do
          similarity >= 0.8 -> 0.15
          similarity >= 0.5 -> 0.0
          similarity >= 0.3 -> -0.10
          true -> -0.20
        end
      else
        0.0
      end

    quality_factor =
      if filename_result.quality && filename_result.quality.resolution != nil do
        0.02
      else
        0.0
      end

    (base + episode_factor + type_factor + season_factor + title_factor + quality_factor)
    |> max(0.0)
    |> min(1.0)
  end

  defp movie_folder_confidence(movie_info, filename_result) do
    base = 0.60

    external_id_bonus = if movie_info.external_id != nil, do: 0.30, else: 0.0
    year_bonus = if movie_info.year != nil, do: 0.05, else: 0.0

    title_agreement_bonus =
      if filename_result.title != nil do
        if Text.title_similarity(movie_info.title, filename_result.title) >= 0.7 do
          0.05
        else
          0.0
        end
      else
        0.0
      end

    min(base + external_id_bonus + year_bonus + title_agreement_bonus, 1.0)
  end
end
