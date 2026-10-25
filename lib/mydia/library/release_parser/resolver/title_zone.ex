defmodule Mydia.Library.ReleaseParser.Resolver.TitleZone do
  @moduledoc """
  The resolver's title-zone rules: which vocabulary words in front of the
  first anchor are title words rather than tags.

  `reclaim/2` runs on the per-token slates before singleton resolution and
  turns a language or revision word that reads as part of the title back
  into a title candidate. `title_word_tag?/3` runs on the resolved
  assignments and tells the resolver which audio and HDR tokens sit in
  front of title words, so they never reach the quality extractor.

  ## Byte safety

  No `String.slice/3` or `String.length/1` calls anywhere, same rule as
  the rest of the release_parser/ tree.
  """

  alias Mydia.Library.ReleaseParser.Candidate
  alias Mydia.Library.ReleaseParser.Token

  @revision_labels [:proper, :repack]

  # ---- Title-word reclamation ----
  #
  # A title word that is also a language tag ("Italian", "Multi") has only
  # its language label left after per_token_best/1: the classifier gives a
  # title fallback only to tokens no vocabulary matched, and the title-zone
  # penalty leaves these above @vocab_min_confidence. A lone language word
  # followed by a plain title word is part of the title
  # ("The.Italian.Harbor"), and so is a single language word that is the
  # whole title zone ("French.2031"). Reclaiming runs before singleton
  # resolution, so a reclaimed word reports no language and cannot displace
  # a real tag. A tag at the end of the title zone ("Show.S01.FRENCH.1080p")
  # and words of a tag run ("MULTi.BluRay.x264") are not reclaimed here.
  #
  # Revision words ("The.Proper.Way", "Repack.2020") follow the same rule;
  # a PROPER closing the title zone ("Show.PROPER.1080p") stays a flag.
  #
  # Only language and revision words are reclaimed, not the other vocab-derived labels
  # (source, codec, hdr, audio, streaming_service, release_group). A
  # quality word ("HDTV", "DVD", "x264") sitting next to a title word is
  # usually not part of the title. It's release noise the parser has no
  # vocabulary for ("Series.10910.hdtv-lol"), and reclaiming it folded that
  # noise straight into already-wrong titles with no corresponding fix
  # anywhere else.

  @reclaimed_fallback_confidence 0.3

  @doc """
  Reclaims title-zone language and revision words as title candidates.
  Takes and returns the resolver's `[{token, candidates}]` slates.
  """
  @spec reclaim([{Token.t(), [Candidate.t()]}], non_neg_integer() | :infinity) ::
          [{Token.t(), [Candidate.t()]}]
  def reclaim(per_token, boundary) do
    {title_zone, rest} =
      Enum.split_while(per_token, fn {token, _} -> in_title_zone?(token, boundary) end)

    reclaim_zone(title_zone, boundary) ++ rest
  end

  defp reclaim_zone([{token, cands}], boundary) when boundary != :infinity do
    case slate_kind(cands) do
      kind when kind in [:language, :revision] ->
        [{token, [reclaimed_candidate(max_confidence(cands) * 0.5)]}]

      _ ->
        [{token, cands}]
    end
  end

  defp reclaim_zone(title_zone, _boundary) do
    kinds = Enum.map(title_zone, fn {_, cands} -> slate_kind(cands) end)
    previous_kinds = [nil | kinds]
    next_entries = Enum.drop(title_zone, 1) ++ [nil]

    # Enum.zip/1 truncates to the shortest list, aligning each token with its kind, prior kind, and next entry.
    [title_zone, kinds, previous_kinds, next_entries]
    |> Enum.zip()
    |> Enum.map(&maybe_reclaim/1)
  end

  defp maybe_reclaim({{token, cands}, :language, previous_kind, {_, next_cands}})
       when previous_kind != :language do
    if slate_kind(next_cands) == :plain,
      do: {token, [reclaimed_candidate(neighbor_confidence(next_cands))]},
      else: {token, cands}
  end

  # `PROPER.REAL.RERIP` qualifies the revision, so REAL after one is not
  # the title word that would make PROPER a title word too.
  defp maybe_reclaim({{token, cands}, :revision, previous_kind, {next_token, next_cands}})
       when previous_kind != :revision do
    if slate_kind(next_cands) == :plain and String.upcase(next_token.value) != "REAL",
      do: {token, [reclaimed_candidate(neighbor_confidence(next_cands))]},
      else: {token, cands}
  end

  defp maybe_reclaim({entry, _kind, _previous_kind, _next}), do: entry

  @doc """
  True for a token in the title zone with a title word after it, still
  inside the title zone ("Fake.Dts.Story.2020", "Hdr.Fake.Story.2020").
  Without anchors there is no boundary and nothing is cut.
  """
  @spec title_word_tag?(Token.t(), [{Token.t(), Candidate.t()}], non_neg_integer() | :infinity) ::
          boolean()
  def title_word_tag?(_token, _assignments, :infinity), do: false

  def title_word_tag?(%Token{byte_offset: offset} = token, assignments, boundary) do
    in_title_zone?(token, boundary) and
      Enum.any?(assignments, fn {other, c} ->
        c.label == :title_candidate and other.byte_offset > offset and
          in_title_zone?(other, boundary)
      end)
  end

  defp in_title_zone?(_token, :infinity), do: true
  defp in_title_zone?(%Token{byte_offset: offset}, boundary), do: offset < boundary

  defp slate_kind([]), do: :plain

  defp slate_kind(cands) do
    cond do
      Enum.any?(cands, &(&1.label == :title_candidate)) -> :plain
      Enum.all?(cands, &(&1.label == :language)) -> :language
      Enum.all?(cands, &(&1.label in @revision_labels)) -> :revision
      true -> :other
    end
  end

  defp reclaimed_candidate(confidence) do
    %Candidate{label: :title_candidate, value: nil, confidence: confidence, zone: :title}
  end

  defp neighbor_confidence([]), do: @reclaimed_fallback_confidence
  defp neighbor_confidence(cands), do: max_confidence(cands)

  defp max_confidence(cands), do: cands |> Enum.map(& &1.confidence) |> Enum.max()
end
