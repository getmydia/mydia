defmodule Mydia.Subtitles.Scoring do
  @moduledoc """
  Ranks subtitle search results against the file they are meant to accompany.

  Ranking used to run on provider-reported signals alone: a hash match, a
  metadata id, a rating, a download count. SubDL reports none of the first
  three and has no hash search, so every result the relay returned scored
  exactly 50, the metadata bonus, which is a property of the search rather than
  of the result. The list was ordered by nothing.

  The signal that does discriminate is the release name. A subtitle timed
  against a particular release almost always fits any file of that release, so
  comparing the candidate's release name to the file's own name separates a
  good match from a coincidence. Both sides go through
  `Mydia.Library.ReleaseParser`, which is corpus tested and already the
  production parser for imports and scanning, rather than a second ad hoc
  tokenizer here.

  Nothing is ever subtracted. An unmatched factor scores zero and is reported
  as unmatched, which the UI shows, but a wrong-source subtitle still beats no
  subtitle, so ranking it below a nameless one would be wrong.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.QualityExtractor
  alias Mydia.Library.Structs.Quality

  defmodule Factor do
    @moduledoc """
    One scored dimension of a result, and why it earned what it earned.

    `detail` carries the reference's value, meaning what this media file is,
    so an unmatched row tells the operator what the subtitle failed to match
    rather than restating the subtitle's own name.

    `max` is this factor's ceiling. It rides on the struct so a renderer can
    colour a row by the fraction earned without keeping its own copy of the
    weight table, which would be free to drift from the real one.
    """

    @type t :: %__MODULE__{
            key: atom(),
            label: String.t(),
            detail: String.t() | nil,
            matched: boolean(),
            points: integer(),
            max: integer()
          }

    @enforce_keys [:key, :label, :matched, :points, :max]
    defstruct [:key, :label, :detail, :matched, :points, :max]
  end

  defmodule Reference do
    @moduledoc """
    What the media file is, in the release parser's standard vocabulary.

    Built once per search rather than once per result: parsing is the expensive
    half of scoring and the reference does not vary across candidates.
    """

    @type t :: %__MODULE__{
            release_group: String.t() | nil,
            resolution: String.t() | nil,
            source: String.t() | nil,
            codec: String.t() | nil,
            audio: String.t() | nil
          }

    defstruct [:release_group, :resolution, :source, :codec, :audio]
  end

  @scoring_weights %{
    hash_match: 100,
    metadata_match: 50,
    rating: 20,
    popularity: 10
  }

  # The release block totals 50. Release group dominates because the same group
  # almost always means the same timings; audio is worth least because it
  # merely proxies for the same encode.
  @release_weights [
    {:release_group, "Release group", 20},
    {:source, "Source", 12},
    {:resolution, "Resolution", 10},
    {:codec, "Codec", 5},
    {:audio, "Audio", 3}
  ]

  @doc """
  Builds the reference a search scores its results against.

  Returns nil for a nil media file, which callers without one pass through.
  """
  @spec build_reference(MediaFile.t() | nil) :: Reference.t() | nil
  def build_reference(nil), do: nil

  def build_reference(%MediaFile{} = media_file) do
    parsed = ReleaseParser.parse(MediaFile.display_name(media_file), standardize: true)
    quality = parsed.quality || %Quality{}

    # A file named "S01E03.mkv" parses to nothing. The analyzed columns know
    # what the stream actually is, so they fill the two fields they cover, run
    # through the parser's own standardizer so both sides speak one vocabulary.
    # There is no column for a release group or a source, and the audio column
    # holds a stream codec ("AAC") where a release name holds a channel layout
    # ("DTS-HD Master Audio"), so comparing those two would only manufacture
    # misses.
    analyzed =
      QualityExtractor.standardize(%Quality{
        resolution: media_file.resolution,
        codec: media_file.codec
      })

    %Reference{
      release_group: parsed.release_group,
      resolution: quality.resolution || analyzed.resolution,
      source: quality.source,
      codec: quality.codec || analyzed.codec,
      audio: quality.audio
    }
  end

  @doc """
  Scores one result, returning its total and the factors that produced it.
  """
  @spec score(map(), map(), Reference.t() | nil) :: {integer(), [Factor.t()]}
  def score(result, search_params, reference) do
    factors =
      release_factors(result, reference) ++
        [metadata_factor(search_params), hash_factor(result, search_params)]

    total =
      Enum.sum(Enum.map(factors, & &1.points)) +
        rating_points(result) +
        popularity_points(result)

    {total, factors}
  end

  ## Private

  defp release_factors(result, reference) do
    candidate = parse_candidate(Map.get(result, :file_name))

    Enum.map(@release_weights, fn {key, label, weight} ->
      reference_value = reference && Map.get(reference, key)
      candidate_value = candidate && Map.get(candidate, key)
      matched = values_match?(reference_value, candidate_value)

      %Factor{
        key: key,
        label: label,
        detail: reference_value,
        matched: matched,
        points: if(matched, do: weight, else: 0),
        max: weight
      }
    end)
  end

  defp parse_candidate(name) when is_binary(name) and name != "" do
    parsed = ReleaseParser.parse(name, standardize: true)
    quality = parsed.quality || %Quality{}

    %Reference{
      release_group: parsed.release_group,
      resolution: quality.resolution,
      source: quality.source,
      codec: quality.codec,
      audio: quality.audio
    }
  end

  defp parse_candidate(_name), do: nil

  # Two nils are an absence of information, not agreement.
  defp values_match?(nil, _candidate), do: false
  defp values_match?(_reference, nil), do: false

  defp values_match?(reference, candidate),
    do: String.downcase(reference) == String.downcase(candidate)

  defp metadata_factor(search_params) do
    matched =
      Map.has_key?(search_params, :imdb_id) or Map.has_key?(search_params, :tmdb_id) or
        Map.has_key?(search_params, :tvdb_id)

    %Factor{
      key: :metadata_match,
      label: "Metadata id",
      detail: nil,
      matched: matched,
      points: if(matched, do: @scoring_weights.metadata_match, else: 0),
      max: @scoring_weights.metadata_match
    }
  end

  defp hash_factor(result, search_params) do
    matched =
      Map.has_key?(search_params, :file_hash) and Map.get(result, :moviehash_match) == true

    %Factor{
      key: :hash_match,
      label: "Hash match",
      detail: nil,
      matched: matched,
      points: if(matched, do: @scoring_weights.hash_match, else: 0),
      max: @scoring_weights.hash_match
    }
  end

  defp rating_points(result) do
    case Map.get(result, :rating) do
      rating when is_number(rating) -> round(rating * @scoring_weights.rating / 10)
      _ -> 0
    end
  end

  defp popularity_points(result) do
    case Map.get(result, :download_count) do
      count when is_integer(count) and count > 0 ->
        round(:math.log10(count) * @scoring_weights.popularity)

      _ ->
        0
    end
  end
end
