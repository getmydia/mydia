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
  alias Mydia.Library.ReleaseParser.ReleaseGroup
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
      |> strip_site_prefix()
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

  # Leading indexer site-branding, e.g. `www.UIndex.org    -    `,
  # `[ www.Torrenting.org ] `, `www.1TamilMV.world - `. Several trackers
  # stamp their domain onto every title they publish. Left in place the
  # tokenizer reads it as part of the show name ("Www Uindex Org Dark
  # Matter"), which `Mydia.Indexers.ReleaseIdentity` then hard-rejects as a
  # different title from an otherwise perfect release.
  #
  # Anchored to a literal `www.` so it cannot bite a real title: no show or
  # film is named "www.something". Only the leading occurrence is removed;
  # trailing site tags in brackets are already handled by @release_group_re.
  #
  # Only an *unambiguous* boundary is stripped, in three forms:
  #
  #   (a) bracketed          `[ www.Torrenting.org ] Movie...`
  #   (b) separator glyph    `www.SiteName.org    -    Example Show...`
  #   (c) bare `www.host.tld` then whitespace   `www.Torrenting.org Movie...`
  #   (d) fullwidth-bracketed  【Site www.host.com】Movie...  (see @fullwidth_site_prefix_re)
  #
  # A greedy `(?:\.[\w-]+)*` label run with a mere "next char is a delimiter"
  # check is NOT safe: in `www.example.com.The Matrix.1999`, `.The` matches as
  # another label and the space after it satisfies the check, so the title
  # parses as "Matrix". Hence (c) permits exactly one TLD label, and (a)/(b)
  # require a bracket or separator that a title word would not be followed by.
  # Anything else, such as a fully run-on `www.Site.org.Movie.Name.2020`, does
  # not match and is left untouched. That is the safe failure: a title we
  # decline to clean, never a title we destroy.
  @site_prefix_re ~r/
    ^\s*
    (?:
        [\[\(\{]\s*www\.[\w.-]+\s*[\]\)\}]\s*      # (a) bracketed host
      |
        www\.[\w-]+(?:\.[\w-]+)*\s*[-–—:|]+\s*     # (b) host then separator
      |
        www\.[\w-]+\.[a-z]{2,6}\s+                 # (c) host then whitespace
    )
  /ix

  # Fullwidth-bracketed site branding, "【高清影视之家发布 www.host.com】" or
  # "［www.host.com］", often with site text before the host. Kept apart from
  # @site_prefix_re because it needs `u` for the multibyte brackets, and `u`
  # would switch that pattern's \w to Unicode word characters.
  @fullwidth_site_prefix_re ~r/^\s*(?:【[^】]*www\.[^】]*】|［[^］]*www\.[^］]*］)\s*/iu

  defp strip_site_prefix(filename) do
    stripped =
      filename
      |> maybe_strip_fullwidth_site_prefix()
      |> then(&Regex.replace(@site_prefix_re, &1, "", global: false))

    # A name that is *nothing but* a site tag has no release information to
    # recover, so keep the original rather than handing the tokenizer "".
    if String.trim(stripped) == "", do: filename, else: stripped
  end

  # `@fullwidth_site_prefix_re` needs the `u` modifier for its multibyte
  # brackets, which requires the subject to be valid UTF-8 or Erlang's `re`
  # raises `ArgumentError`. Malformed byte sequences are a real category in
  # release filenames (older filesystems, mis-declared tracker encodings),
  # and this runs unconditionally on every scanned/imported file, so an
  # invalid-UTF-8 filename skips this step. `@site_prefix_re` has no
  # multibyte literals and needs no `u`, so it still runs and the tokenizer
  # still gets a shot at the rest. That is the safe failure: a title we
  # decline to clean, never a title we destroy.
  defp maybe_strip_fullwidth_site_prefix(filename) do
    if String.valid?(filename) do
      Regex.replace(@fullwidth_site_prefix_re, filename, "", global: false)
    else
      filename
    end
  end

  defp tokenize_classify_resolve(filename, target) do
    # Pre-pass: detect a trailing release-group separator (`-GROUP`)
    # and rewrite the dash to a space so the tokenizer splits it
    # cleanly. The dash before a trailing group has no semantic meaning
    # we want to preserve — it just makes the codec/quality token
    # downstream attach to the group name.
    {prepared, detected_group, group_offset} = ReleaseGroup.strip_trailing(filename)

    tokens = Tokenizer.tokenize(prepared)
    anchors = Tokenizer.anchor_positions(prepared)

    classified =
      tokens
      |> Classifier.classify(anchors)
      |> ReleaseGroup.drop_sources(group_offset)

    resolver_result = Resolver.resolve(classified, target)

    # Pre-pass detection wins over vocab matches: the trailing
    # `-GROUP` is more authoritative than a token that happens to be
    # in the release-groups vocabulary (which often appears as a site
    # tag in trailing brackets, e.g. `[rarbg]`).
    final_group = detected_group || resolver_result.release_group

    Map.put(resolver_result, :release_group, final_group)
  end

  defp build_parsed_file_info(resolver_result, filename, opts) do
    quality = QualityExtractor.extract(resolver_result, opts)

    title = resolver_result.title
    type = resolver_result.type
    year = resolver_result.year
    season = resolver_result.season
    episodes = normalize_episodes(resolver_result.episodes)
    release_group = resolver_result.release_group

    # Type inference: episode marker → tv_show; else use the resolver
    # type, with a fallback to V2-style infer_media_type for the
    # title/year/quality cases.
    type =
      cond do
        type == :tv_show -> :tv_show
        season != nil or episodes != nil -> :tv_show
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
      if filename_result.quality.resolution != nil do
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
