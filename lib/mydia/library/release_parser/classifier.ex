defmodule Mydia.Library.ReleaseParser.Classifier do
  @moduledoc """
  Stage 2 of the parser: turn tokens into `%Candidate{}` lists.

  The classifier doesn't decide anything yet — it only proposes labels
  per token. The resolver (Unit 5) picks a globally consistent
  assignment. That separation keeps each unit small and lets us test
  vocabulary lookup independently of conflict resolution.

  ## Sources of candidates

  1. **Vocabulary lookup** — `Vocabulary.lookup/1` per token value;
     each matching entry contributes one candidate with zone-adjusted
     confidence (base confidence + `title_zone_bonus` or
     `metadata_zone_bonus`).
  2. **Anchor tagging** — year, resolution and episode-marker positions
     from `Tokenizer.anchor_positions/1` are matched back to tokens by
     byte offset and tagged with their `:year` / `:resolution` /
     `:episode_marker` label.
  3. **Title fallback** — every title-zone token that received no other
     candidate gets a `:title_candidate` with confidence falling off
     linearly from the start of the input (earliest tokens = strongest
     title evidence).

  ## Byte-safety

  This module operates on byte offsets only. **No `String.slice/3` or
  `String.length/1` calls anywhere** — same rule as the tokenizer.
  """

  alias Mydia.Library.ReleaseParser.Candidate
  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.ReleaseParser.Tokenizer
  alias Mydia.Library.ReleaseParser.Vocabulary
  alias Mydia.Library.ReleaseParser.VocabularyEntry

  @title_fallback_max_confidence 0.6
  @title_fallback_min_confidence 0.15

  @doc """
  Classify a list of tokens against the given anchor positions. Returns
  the same tokens (preserving order, offsets, and bracket context) with
  their `:candidates` field populated.
  """
  @spec classify([Token.t()], Tokenizer.anchors()) :: [Token.t()]
  def classify(tokens, anchors) when is_list(tokens) and is_map(anchors) do
    boundary = title_boundary(anchors)
    total_tokens = length(tokens)

    tokens
    |> Enum.with_index()
    |> Enum.map(fn {%Token{} = token, index} ->
      zone = zone_for(token, boundary)
      candidates = candidates_for(token, anchors, zone, index, total_tokens)
      %Token{token | candidates: candidates}
    end)
  end

  # ---- Internals ----

  defp candidates_for(%Token{} = token, anchors, zone, index, total) do
    anchor_candidates = anchor_candidates(token, anchors, zone)
    vocab_candidates = vocab_candidates(token, zone)

    case anchor_candidates ++ vocab_candidates do
      [] ->
        if zone == :title do
          [title_fallback_candidate(index, total)]
        else
          []
        end

      candidates ->
        candidates
    end
  end

  defp anchor_candidates(%Token{byte_offset: offset, byte_length: len}, anchors, zone) do
    [
      anchor_label_for(offset, len, anchors.year, :year, 0.95, zone),
      anchor_label_for(offset, len, anchors.resolution, :resolution, 0.98, zone),
      anchor_label_for(offset, len, anchors.episode_marker, :episode_marker, 0.98, zone)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp anchor_label_for(_offset, _len, nil, _label, _confidence, _zone), do: nil

  defp anchor_label_for(offset, len, anchor_pos, label, confidence, zone) do
    if offset <= anchor_pos and anchor_pos < offset + len do
      %Candidate{label: label, value: nil, confidence: confidence, zone: zone}
    else
      nil
    end
  end

  defp vocab_candidates(%Token{value: value}, zone) do
    entries =
      case Vocabulary.lookup(value) do
        [] -> Vocabulary.lookup(strip_trailing_punct(value))
        list -> list
      end

    Enum.map(entries, fn %VocabularyEntry{} = entry ->
      %Candidate{
        label: entry.label,
        value: entry.canonical,
        confidence: clamp(entry.confidence + zone_bonus(entry, zone)),
        zone: zone
      }
    end)
  end

  # Strip trailing punctuation bytes (e.g. `DD+` → `DD`, and the comma of a
  # listed tag set, `[2023, HEVC, HDR10]`). Limited to ASCII so we don't
  # touch multibyte token text.
  defp strip_trailing_punct(""), do: ""

  defp strip_trailing_punct(value) do
    size = byte_size(value)
    last = :binary.at(value, size - 1)

    if last in ~c"+!?'," do
      strip_trailing_punct(binary_part(value, 0, size - 1))
    else
      value
    end
  end

  defp zone_bonus(%VocabularyEntry{} = entry, :title), do: entry.title_zone_bonus
  defp zone_bonus(%VocabularyEntry{} = entry, :metadata), do: entry.metadata_zone_bonus

  defp zone_for(%Token{byte_offset: offset}, boundary) do
    if offset < boundary, do: :title, else: :metadata
  end

  # The boundary is the lowest non-nil anchor position. If no anchors
  # were detected we treat every token as title-zone, which matches V2's
  # behavior when no year / resolution / episode marker is present.
  defp title_boundary(anchors) do
    [anchors.year, anchors.resolution, anchors.episode_marker]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :infinity
      positions -> Enum.min(positions)
    end
  end

  # Title-zone tokens that didn't match any vocabulary get a fallback
  # candidate with confidence decaying linearly from the head of the
  # token stream. The decay gives the resolver a tie-break preference
  # for tokens nearer the start when assembling the title.
  defp title_fallback_candidate(index, total) when total > 1 do
    ratio = index / (total - 1)
    confidence = @title_fallback_max_confidence - ratio * fallback_span()

    %Candidate{
      label: :title_candidate,
      value: nil,
      confidence: clamp(confidence),
      zone: :title
    }
  end

  defp title_fallback_candidate(_index, _total) do
    %Candidate{
      label: :title_candidate,
      value: nil,
      confidence: @title_fallback_max_confidence,
      zone: :title
    }
  end

  defp fallback_span,
    do: @title_fallback_max_confidence - @title_fallback_min_confidence

  defp clamp(c) when c < 0.0, do: 0.0
  defp clamp(c) when c > 1.0, do: 1.0
  defp clamp(c), do: c
end
