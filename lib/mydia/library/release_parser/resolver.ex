defmodule Mydia.Library.ReleaseParser.Resolver do
  @moduledoc """
  Stage 3 of the V3 release parser: pick a globally consistent
  assignment of candidate labels to tokens, optionally locked to a
  target context, and emit per-field confidence.

  Inputs:

  - `tokens` — list of `%Token{}` with `:candidates` already populated
    by the classifier.
  - `target` — optional `%TargetContext{}`. When present, type / title /
    year are locked to the target; season + episodes + quality are still
    parsed from tokens.
  - `opts` — currently unused; reserved for future tuning knobs.

  Returns a map shaped for the facade in Unit 6 to massage into a
  `%ParsedFileInfo{}`:

      %{
        type: :movie | :tv_show | :unknown,
        title: String.t() | nil,
        year: integer() | nil,
        season: integer() | nil,
        episodes: [integer()] | nil,
        absolute_episode: integer() | nil,
        quality_tokens: [%{label: atom(), value: term(), token: %Token{}}],
        release_group: String.t() | nil,
        language: String.t() | nil,
        field_confidence: %{atom() => float()},
        engine_flags: %{atom() => term()} | nil,
        binding_confidence: float() | nil
      }

  ## Algorithm — boring on purpose

  1. For each token, pick the single best candidate per label
     (highest-confidence wins per-token).
  2. Resolve label-wide conflicts: only one `:year`, `:resolution`,
     `:episode_marker`, `:source`, `:hdr`, `:release_group` and one
     `:codec` candidate may survive. Losing tokens are demoted to
     `:title_candidate` with half their original confidence.
  3. Assemble the season + episode list from the surviving episode
     marker token plus any adjacent `E\\d+` continuation tokens.
  4. When `target` is provided, lock `type / title / year` and compute
     `binding_confidence` against `target.title + target.alt_titles`
     via `Mydia.Library.Text.title_similarity/2` (canonicalized
     downcase + accent fold + Jaro fallback).
  5. When unbound, assemble the title from the remaining
     `:title_candidate` tokens in the title zone via
     `TitleAssembler.assemble/2` and infer the type.
  6. Emit per-field confidence directly from the candidate that
     produced each populated field.

  ## Byte safety

  No `String.slice/3` or `String.length/1` calls anywhere — same rule as
  the rest of the release_parser/ tree.
  """

  alias Mydia.Library.ReleaseParser.Candidate
  alias Mydia.Library.ReleaseParser.Config
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.ReleaseParser.TitleAssembler
  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.Text

  # Labels that may only have one resolved candidate across the entire
  # token stream. Conflicts are settled by highest confidence.
  @singleton_labels [
    :year,
    :resolution,
    :episode_marker,
    :season_marker,
    :source,
    :hdr,
    :codec,
    :release_group,
    :language,
    :streaming_service
  ]

  # Vocab-derived labels whose low-confidence candidates should be
  # dropped before conflict resolution. Anchor labels (year, resolution,
  # episode_marker) are never filtered because they're regex-detected
  # and inherently high-confidence. The "Madame Web" carve-out depends
  # on this: `Web` in the title zone gets source-confidence ~0.15 from
  # the title-zone penalty, well below the threshold, and is dropped so
  # the title assembler can claim the token.
  @vocab_filtered_labels [
    :source,
    :codec,
    :hdr,
    :audio,
    :language,
    :streaming_service,
    :release_group
  ]

  @vocab_min_confidence 0.4

  # Labels mapped through to `quality_tokens` for QualityExtractor in
  # Unit 6.
  @quality_labels [:resolution, :source, :codec, :hdr, :audio]

  @doc """
  Resolve the given tokens to a field assignment.
  """
  @spec resolve([Token.t()], TargetContext.t() | nil, keyword()) :: map()
  def resolve(tokens, target, opts \\ [])

  def resolve(tokens, target, _opts) when is_list(tokens) do
    boundary = title_boundary_for(tokens)

    {assignments, demoted_tokens} =
      tokens
      |> per_token_best()
      |> resolve_singleton_conflicts()

    assignments_map = group_assignments_by_token(assignments)

    {season, episodes, episode_token, episode_conf} =
      extract_episode_info(tokens, assignments_map)

    absolute_episode =
      resolve_absolute_episode(tokens, target, assignments_map, season, episodes)

    year_pick = pick_assignment(assignments, :year)
    year_value = pick_year_value(year_pick)
    year_confidence = pick_confidence(year_pick)

    quality_tokens = collect_quality_tokens(assignments)
    release_group = pick_release_group(assignments)
    language = pick_language(assignments)

    inferred_type = infer_type(episode_token, year_pick)

    {title_value, title_confidence} =
      assemble_title(tokens, assignments_map, demoted_tokens, boundary)

    base = %{
      type: inferred_type,
      title: title_value,
      year: year_value,
      season: season,
      episodes: episodes,
      absolute_episode: absolute_episode,
      quality_tokens: quality_tokens,
      release_group: release_group,
      language: language,
      all_tokens: tokens,
      field_confidence: %{},
      engine_flags: nil,
      binding_confidence: nil
    }

    base
    |> put_field_confidence(:year, year_confidence)
    |> put_field_confidence(:season, season_confidence(episode_token, episode_conf, season))
    |> put_field_confidence(:episodes, episode_conf)
    |> put_field_confidence(:title, title_confidence)
    |> apply_quality_confidence(quality_tokens)
    |> apply_release_group_confidence(release_group, assignments)
    |> apply_language_confidence(language, assignments)
    |> apply_target_binding(target, tokens)
  end

  # ---- Per-token best candidate ----

  defp per_token_best(tokens) do
    Enum.map(tokens, fn %Token{candidates: candidates} = token ->
      best =
        candidates
        |> Enum.group_by(& &1.label)
        |> Enum.map(fn {_label, group} -> Enum.max_by(group, & &1.confidence) end)
        |> Enum.reject(&drop_weak_vocab?/1)

      {token, best}
    end)
  end

  defp drop_weak_vocab?(%Candidate{label: label, confidence: conf})
       when label in @vocab_filtered_labels and conf < @vocab_min_confidence,
       do: true

  defp drop_weak_vocab?(_), do: false

  # ---- Singleton-conflict resolution ----
  #
  # Walks each singleton label and keeps the highest-confidence
  # (token, candidate) pair; for every other token that had a candidate
  # for that label, the candidate is *removed* from its slate so the
  # token only contributes through its remaining labels (or
  # `:title_candidate`). If a losing token has no other candidates we
  # record a demoted title fallback.

  defp resolve_singleton_conflicts(per_token) do
    {final, demoted} =
      Enum.reduce(@singleton_labels, {per_token, %{}}, &resolve_one_label/2)

    assignments = build_assignments(final)
    {assignments, demoted}
  end

  defp resolve_one_label(label, {per_token, demoted}) do
    contenders =
      per_token
      |> Enum.flat_map(fn {token, cands} ->
        case Enum.find(cands, &(&1.label == label)) do
          nil -> []
          cand -> [{token, cand}]
        end
      end)

    case contenders do
      [] ->
        {per_token, demoted}

      [{_, _}] ->
        {per_token, demoted}

      multi ->
        winner_pair = Enum.max_by(multi, fn {_, c} -> c.confidence end)
        losers = multi -- [winner_pair]

        per_token = strip_losers(per_token, losers, label)
        demoted = record_demotions(demoted, losers)
        {per_token, demoted}
    end
  end

  defp strip_losers(per_token, losers, label) do
    loser_token_ids = MapSet.new(losers, fn {tok, _} -> token_key(tok) end)

    Enum.map(per_token, fn {token, cands} ->
      if MapSet.member?(loser_token_ids, token_key(token)) do
        {token, Enum.reject(cands, &(&1.label == label))}
      else
        {token, cands}
      end
    end)
  end

  defp record_demotions(demoted, losers) do
    Enum.reduce(losers, demoted, fn {token, cand}, acc ->
      Map.update(acc, token_key(token), [cand], &[cand | &1])
    end)
  end

  # Build {token, winning_candidate} list from the surviving per-token
  # slates. A token may have multiple candidates of different labels; we
  # keep one entry per (token, label) pair so the downstream pickers can
  # find by label.
  defp build_assignments(per_token) do
    Enum.flat_map(per_token, fn {token, cands} ->
      Enum.map(cands, fn cand -> {token, cand} end)
    end)
  end

  # ---- Field pickers ----

  defp pick_assignment(assignments, label) do
    case Enum.filter(assignments, fn {_, c} -> c.label == label end) do
      [] -> nil
      list -> Enum.max_by(list, fn {_, c} -> c.confidence end)
    end
  end

  defp pick_year_value(nil), do: nil

  defp pick_year_value({%Token{value: value}, _candidate}) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp pick_confidence(nil), do: nil
  defp pick_confidence({_, %Candidate{confidence: c}}), do: c

  defp collect_quality_tokens(assignments) do
    @quality_labels
    |> Enum.flat_map(fn label ->
      assignments
      |> Enum.filter(fn {_, c} -> c.label == label end)
      |> case do
        [] -> []
        list when label == :audio -> Enum.map(list, &to_quality_entry/1)
        list -> [list |> Enum.max_by(fn {_, c} -> c.confidence end) |> to_quality_entry()]
      end
    end)
  end

  defp to_quality_entry({token, %Candidate{} = c}) do
    %{label: c.label, value: c.value || token.value, token: token, confidence: c.confidence}
  end

  defp pick_release_group(assignments) do
    case pick_assignment(assignments, :release_group) do
      nil -> nil
      {_, %Candidate{value: value}} when is_binary(value) -> value
      {%Token{value: value}, _} -> value
    end
  end

  defp pick_language(assignments) do
    case pick_assignment(assignments, :language) do
      nil -> nil
      {_, %Candidate{value: value}} when is_binary(value) -> value
      {%Token{value: value}, _} -> value
    end
  end

  # ---- Episode extraction ----

  defp extract_episode_info(tokens, assignments_map) do
    # Find the episode marker token (the one that survived singleton
    # conflict resolution).
    marker =
      Enum.find(tokens, fn token ->
        case assignments_map_get(assignments_map, token) do
          nil -> false
          cands -> Enum.any?(cands, &(&1.label == :episode_marker))
        end
      end)

    case marker do
      nil ->
        # Look for a season-marker-only token (S01 without E).
        season_only(tokens, assignments_map)

      %Token{value: value} = token ->
        {season, episodes} =
          case parse_episode_marker(value) do
            {nil, []} -> verbose_season_extract(tokens, token)
            other -> other
          end

        extended = extend_with_adjacent(tokens, token, episodes)
        marker_cand = find_candidate(assignments_map, token, :episode_marker)
        confidence = if marker_cand, do: marker_cand.confidence, else: 0.95
        {season, extended, token, confidence}
    end
  end

  # `Season N` / `Season N Episode M` verbose form. The marker token is
  # `Season`. Look at the immediate followers for the integer values.
  defp verbose_season_extract(tokens, %Token{} = marker) do
    after_marker =
      tokens
      |> Enum.drop_while(fn t -> token_key(t) != token_key(marker) end)
      |> Enum.drop(1)

    case after_marker do
      [%Token{value: season_str} | rest] ->
        case Integer.parse(season_str) do
          {season, ""} ->
            episodes =
              case verbose_episode_extract(rest) do
                {:ok, eps} -> eps
                :error -> []
              end

            {season, episodes}

          _ ->
            {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp verbose_episode_extract([%Token{value: word} | [%Token{value: ep_str} | _]]) do
    # The episode-number token may have trailing punctuation (e.g.
    # "Episode 1- The Deal" leaves "1-" attached because the tokenizer
    # only splits on whitespace / dot / underscore). Match the leading
    # digit run instead of demanding a clean integer.
    if String.downcase(word) == "episode" do
      case Regex.run(~r/^(\d+)(?![a-zA-Z\d])/, ep_str) do
        [_, digits] -> {:ok, [String.to_integer(digits)]}
        _ -> :error
      end
    else
      :error
    end
  end

  defp verbose_episode_extract(_), do: :error

  defp assignments_map_get(map, %Token{} = token) do
    Map.get(map, token_key(token))
  end

  defp find_candidate(map, %Token{} = token, label) do
    case assignments_map_get(map, token) do
      nil -> nil
      cands -> Enum.find(cands, &(&1.label == label))
    end
  end

  defp season_only(tokens, assignments_map) do
    season_token =
      Enum.find(tokens, fn token ->
        case assignments_map_get(assignments_map, token) do
          nil -> false
          cands -> Enum.any?(cands, &(&1.label == :season_marker))
        end
      end)

    case season_token do
      nil ->
        {nil, nil, nil, nil}

      %Token{value: value} = token ->
        case parse_episode_marker(value) do
          {nil, nil} -> {nil, nil, nil, nil}
          {season, episodes} -> {season, episodes, token, 0.9}
        end
    end
  end

  # Parse the marker value. Handles:
  #   S01E01, S01E01E02, S01E01-E03, S01.E01, S01, 1x05
  # Returns {season, episodes} where season may be nil.
  defp parse_episode_marker(value) do
    cond do
      result = parse_sxxexx(value) -> result
      result = parse_axb(value) -> result
      result = parse_season_only(value) -> result
      result = parse_verbose_season(value) -> result
      result = parse_absolute_episode(value) -> result
      true -> {nil, nil}
    end
  end

  # Verbose "Season N" (and Sometimes "Episode N") tokens. The marker
  # value will be just "Season" — the season number lives in the next
  # token. We return {nil, nil} here and rely on extend_with_adjacent
  # for the actual extraction (handled below).
  defp parse_verbose_season(value) do
    if Regex.match?(~r/^season$/i, value), do: {nil, []}, else: nil
  end

  defp parse_sxxexx(value) do
    # Accept S01E01, S01-E01, S01 E01, S01.E01 separators between
    # season and episode digits.
    case Regex.run(~r/^[Ss](\d{1,3})(?:[-\s.]?[Ee](\d{1,4}))?/, value) do
      [_, season_str] ->
        {String.to_integer(season_str), []}

      [_, season_str, ep_str] ->
        season = String.to_integer(season_str)
        first_ep = String.to_integer(ep_str)
        rest = additional_episodes(value)
        {season, dedupe_sorted([first_ep | rest])}

      _ ->
        nil
    end
  end

  defp parse_axb(value) do
    case Regex.run(~r/^(\d{1,3})[xX](\d{1,4})$/, value) do
      [_, season_str, ep_str] ->
        {String.to_integer(season_str), [String.to_integer(ep_str)]}

      _ ->
        nil
    end
  end

  defp parse_season_only(value) do
    case Regex.run(~r/^[Ss](\d{1,3})$/, value) do
      [_, season_str] -> {String.to_integer(season_str), []}
      _ -> nil
    end
  end

  # Standalone absolute episode numbering with no season marker (`E18`,
  # `E018`, `E1234`) — common in anime. Defaults to season 1, matching
  # the historical FileParser (V1) behavior this replaces.
  defp parse_absolute_episode(value) do
    case Regex.run(~r/^[Ee](\d{2,4})$/, value) do
      [_, ep_str] -> {1, [String.to_integer(ep_str)]}
      _ -> nil
    end
  end

  # Pull every E-number after the first E in the marker value
  # (S01E01E02E03 -> [2, 3], plus expansion for ranges like E01-E03,
  # plus continuation chains like E96-97-98-99-100).
  defp additional_episodes(value) do
    parts = Regex.scan(~r/[Ee](\d{1,4})(?:[-–][Ee]?(\d{1,4}))?/, value)

    base =
      parts
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {[_, _ep], 0} -> []
        {[_, ep], _i} -> [String.to_integer(ep)]
        {[_, start_s, end_s], 0} -> range_expand(start_s, end_s) |> tl()
        {[_, start_s, end_s], _i} -> range_expand(start_s, end_s)
      end)

    base ++ continuation_chain(value)
  end

  # Continuation chain: after the last `E\d+-\d+` match, look for
  # additional `-\d+` segments. Captures patterns like
  # `S26E96-97-98-99-100` where the chain isn't repeating `E`.
  defp continuation_chain(value) do
    case Regex.run(~r/[Ee]\d{1,4}[-–]\d{1,4}((?:[-–]\d{1,4})+)/, value) do
      [_, tail] ->
        Regex.scan(~r/(\d{1,4})/, tail)
        |> Enum.map(fn [_, n] -> String.to_integer(n) end)

      _ ->
        []
    end
  end

  defp range_expand(start_s, end_s) do
    s = String.to_integer(start_s)
    e = String.to_integer(end_s)
    if s <= e, do: Enum.to_list(s..e), else: [s]
  end

  # Extend the episode list with continuation tokens that immediately
  # follow the marker (e.g. `S01E01 E02 E03`).
  defp extend_with_adjacent(tokens, %Token{} = marker, episodes) do
    after_marker =
      tokens
      |> Enum.drop_while(fn t -> token_key(t) != token_key(marker) end)
      |> Enum.drop(1)
      |> Enum.take_while(&continuation_token?/1)

    extra =
      after_marker
      |> Enum.flat_map(&continuation_episodes/1)

    case episodes do
      nil -> nil
      [] when extra == [] -> []
      list -> dedupe_sorted(list ++ extra)
    end
  end

  defp continuation_token?(%Token{value: value}) do
    Regex.match?(~r/^[Ee]\d{1,4}(?:[-–][Ee]?\d{1,4})?$/, value)
  end

  defp continuation_episodes(%Token{value: value}) do
    case Regex.run(~r/^[Ee](\d{1,4})(?:[-–][Ee]?(\d{1,4}))?$/, value) do
      [_, single] ->
        [String.to_integer(single)]

      [_, start_s, end_s] ->
        range_expand(start_s, end_s)

      _ ->
        []
    end
  end

  defp dedupe_sorted(list) when is_list(list) do
    list |> Enum.uniq() |> Enum.sort()
  end

  # ---- Absolute episode resolution (anime) ----
  #
  # Anime releases are numbered absolutely with no season marker
  # ("Black Clover - 170"), which the tokenizer deliberately does not
  # treat as an episode marker: a bare integer is far more often a
  # year, a resolution or a part number. Resolving it here, gated
  # behind an explicit anime target, keeps the parity suite green
  # (target is always `nil` or non-anime there) while still matching
  # the dominant anime naming convention.
  #
  # A bare integer token only qualifies when:
  #
  #   1. No season/episode marker was already resolved from the
  #      filename (guarded by the first clause below).
  #   2. The target is bound, its `category` is `"anime_series"`, and
  #      it carries a `max_absolute_number` (nil disables the feature,
  #      per `TargetContext` — every non-anime show has nil).
  #   3. The token itself hasn't already won a singleton-label fight
  #      (`:year`, `:resolution`, `:release_group`, etc.) — a token
  #      already claimed as the release year or a quality/group value
  #      is not re-read as an episode number.
  #   4. The token sits outside brackets/parens/braces — real absolute
  #      episode numbers appear bare (`Show - 170`), while brackets and
  #      parens are where quality annotations and hash-style release
  #      tags (`[A1B2C3]`) live.
  #   5. The value falls within `1..max_absolute_number` — this is
  #      what keeps `1080`, `2049` and other large bare numbers from
  #      ever matching.
  defp resolve_absolute_episode(_tokens, _target, _assignments_map, season, episodes)
       when not is_nil(season) or episodes not in [nil, []],
       do: nil

  defp resolve_absolute_episode(
         tokens,
         %TargetContext{category: "anime_series", max_absolute_number: max},
         assignments_map,
         _season,
         _episodes
       )
       when is_integer(max) do
    tokens
    |> Enum.filter(&bare_episode_candidate?(&1, assignments_map))
    |> Enum.map(&String.to_integer(&1.value))
    |> Enum.filter(fn n -> n >= 1 and n <= max end)
    |> List.first()
  end

  defp resolve_absolute_episode(_tokens, _target, _assignments_map, _season, _episodes), do: nil

  defp bare_episode_candidate?(
         %Token{bracket_context: nil, value: value} = token,
         assignments_map
       ) do
    Regex.match?(~r/^\d{1,4}$/, value) and not singleton_claimed?(token, assignments_map)
  end

  defp bare_episode_candidate?(%Token{}, _assignments_map), do: false

  defp singleton_claimed?(%Token{} = token, assignments_map) do
    case assignments_map_get(assignments_map, token) do
      nil -> false
      cands -> Enum.any?(cands, &(&1.label in @singleton_labels))
    end
  end

  # ---- Type inference ----

  defp infer_type(nil, nil), do: :unknown
  defp infer_type(nil, _year), do: :movie
  defp infer_type(_marker, _year), do: :tv_show

  # ---- Title assembly (unbound) ----

  defp assemble_title(tokens, assignments_map, demoted_tokens, boundary) do
    # A token contributes to the title if its surviving slate is empty
    # (all non-title candidates lost their singleton fights) or if its
    # remaining best candidate is `:title_candidate`.
    title_tokens =
      tokens
      |> Enum.filter(fn token ->
        cands = assignments_map_get(assignments_map, token) || []
        title_token?(cands)
      end)

    title_value = TitleAssembler.assemble(title_tokens, boundary)

    confidence =
      cond do
        title_value == nil -> 0.0
        title_tokens == [] -> 0.5
        true -> mean_title_confidence(title_tokens, assignments_map, demoted_tokens)
      end

    {title_value, confidence}
  end

  defp title_token?([]), do: true

  defp title_token?(cands) do
    best = Enum.max_by(cands, & &1.confidence)
    best.label == :title_candidate
  end

  defp mean_title_confidence(title_tokens, assignments_map, demoted_tokens) do
    confidences =
      Enum.map(title_tokens, fn token ->
        case assignments_map_get(assignments_map, token) do
          empty when empty in [nil, []] ->
            # All candidates demoted — use degraded confidence.
            degraded_confidence(demoted_tokens, token)

          cands ->
            cands |> Enum.map(& &1.confidence) |> Enum.max()
        end
      end)

    case confidences do
      [] -> 0.5
      list -> Enum.sum(list) / length(list)
    end
  end

  defp degraded_confidence(demoted_tokens, %Token{} = token) do
    case Map.get(demoted_tokens, token_key(token)) do
      [%Candidate{confidence: c} | _] -> c * 0.5
      _ -> 0.3
    end
  end

  # ---- Confidence aggregation ----

  defp put_field_confidence(result, _field, nil), do: result

  defp put_field_confidence(result, field, value) when is_float(value) do
    update_in(result.field_confidence, &Map.put(&1, field, value))
  end

  defp apply_quality_confidence(result, quality_tokens) do
    Enum.reduce(quality_tokens, result, fn entry, acc ->
      put_field_confidence(acc, quality_field_key(entry.label), entry.confidence)
    end)
  end

  defp quality_field_key(:resolution), do: :resolution
  defp quality_field_key(:source), do: :source
  defp quality_field_key(:codec), do: :codec
  defp quality_field_key(:hdr), do: :hdr_format
  defp quality_field_key(:audio), do: :audio
  defp quality_field_key(other), do: other

  defp apply_release_group_confidence(result, nil, _), do: result

  defp apply_release_group_confidence(result, _group, assignments) do
    case pick_assignment(assignments, :release_group) do
      nil -> result
      {_, %Candidate{confidence: c}} -> put_field_confidence(result, :release_group, c)
    end
  end

  defp apply_language_confidence(result, nil, _), do: result

  defp apply_language_confidence(result, _lang, assignments) do
    case pick_assignment(assignments, :language) do
      nil -> result
      {_, %Candidate{confidence: c}} -> put_field_confidence(result, :language, c)
    end
  end

  defp season_confidence(nil, _, _), do: nil
  defp season_confidence(_token, conf, _season), do: conf

  # ---- Target binding ----

  defp apply_target_binding(result, nil, _tokens), do: result

  defp apply_target_binding(result, %TargetContext{} = target, _tokens) do
    parsed_title_unbound = result.title

    # Lock type / title / year.
    locked_year = target.year || result.year

    result =
      %{
        result
        | type: target.type,
          title: target.title,
          year: locked_year
      }

    # Compute binding confidence by comparing the parsed-would-be title
    # to the target's name + alt titles. Title field_confidence is
    # intentionally NOT clamped to 1.0 when bound — it stays whatever
    # the parser computed from the tokens. This preserves diagnostic
    # signal when binding is wrong (plan: "Decision matrix").
    binding_confidence =
      compute_binding_confidence(parsed_title_unbound, target)

    flags =
      result.engine_flags
      |> ensure_map()
      |> maybe_flag_binding_suspect(binding_confidence, parsed_title_unbound)
      |> maybe_flag_season_out_of_range(result.season, target.known_seasons)

    result = %{result | engine_flags: nil_if_empty_map(flags)}

    # Season-out-of-range penalty.
    result =
      if season_out_of_range?(result.season, target.known_seasons) do
        suggest = Config.suggest_threshold()

        update_in(result.field_confidence, fn fc ->
          Map.update(fc, :season, suggest, fn current -> min(current, suggest) end)
        end)
      else
        result
      end

    # Year confidence: when the target supplies a year, set
    # field_confidence.year = 1.0 (target-locked).
    result =
      case target.year do
        nil -> result
        _y -> put_field_confidence(result, :year, 1.0)
      end

    %{result | binding_confidence: binding_confidence}
  end

  defp compute_binding_confidence(nil, _), do: 0.0

  # Score the parsed title against the target's primary title plus
  # any alt titles. Uses the shared `Library.Text.title_similarity/2`
  # so the parser, metadata matcher, and search seam all canonicalize
  # the same way.
  defp compute_binding_confidence(parsed_title, %TargetContext{title: title, alt_titles: alts}) do
    targets = Enum.reject([title | alts], &(is_nil(&1) or &1 == ""))

    case targets do
      [] ->
        0.0

      _ ->
        targets
        |> Enum.map(&Text.title_similarity(parsed_title, &1))
        |> Enum.max()
    end
  end

  defp ensure_map(nil), do: %{}
  defp ensure_map(%{} = m), do: m

  defp nil_if_empty_map(m) when map_size(m) == 0, do: nil
  defp nil_if_empty_map(m), do: m

  defp maybe_flag_binding_suspect(flags, confidence, parsed_title)
       when is_number(confidence) and confidence < 0.5 do
    flags
    |> Map.put(:binding_suspect, true)
    |> Map.put(:parsed_title_unbound, parsed_title)
  end

  defp maybe_flag_binding_suspect(flags, _confidence, _parsed_title), do: flags

  defp maybe_flag_season_out_of_range(flags, season, known_seasons) do
    if season_out_of_range?(season, known_seasons) do
      Map.put(flags, :season_out_of_range, true)
    else
      flags
    end
  end

  defp season_out_of_range?(nil, _), do: false
  defp season_out_of_range?(_season, []), do: false

  defp season_out_of_range?(season, known) when is_list(known) do
    season not in known
  end

  # ---- Helpers ----

  # Tokens are uniquely identified by their byte offset. We avoid
  # using the struct itself as a map key so that semantic equality
  # works even when candidates change shape.
  defp token_key(%Token{byte_offset: offset, byte_length: len}), do: {offset, len}

  defp group_assignments_by_token(assignments) do
    Enum.reduce(assignments, %{}, fn {token, cand}, acc ->
      Map.update(acc, token_key(token), [cand], fn list -> [cand | list] end)
    end)
  end

  defp title_boundary_for(tokens) do
    anchors =
      tokens
      |> Enum.flat_map(fn %Token{candidates: cands, byte_offset: o} ->
        cands
        |> Enum.filter(fn c -> c.label in [:year, :resolution, :episode_marker] end)
        |> Enum.map(fn _ -> o end)
      end)

    case anchors do
      [] -> :infinity
      list -> Enum.min(list)
    end
  end
end
