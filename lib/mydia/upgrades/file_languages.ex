defmodule Mydia.Upgrades.FileLanguages do
  @moduledoc """
  The audio languages a file on disk carries, and how they compare under a
  `Mydia.Media.AudioLanguagePolicy`.

  ffprobe is the authority for a file that exists: its languages are the
  canonical codes on its audio streams. A stream tagged `und`, or not tagged
  at all, contributes nothing, and a file whose audio streams contribute
  nothing has unknown languages. Unknown means Mydia cannot tell, so it never
  counts as a gap and never wins or loses a comparison.

  Everything here is pure.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Metadata.LanguageCode

  @type languages :: {:known, [String.t()]} | :unknown

  @doc "The sorted canonical audio languages on `file`, or `:unknown`."
  @spec detect(MediaFile.t() | nil) :: languages()
  def detect(%MediaFile{metadata: %{streams: streams}}) when is_list(streams) do
    streams
    |> Enum.filter(&match?(%StreamInfo{type: :audio}, &1))
    |> Enum.map(&LanguageCode.canonical(&1.language))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> :unknown
      languages -> {:known, languages}
    end
  end

  def detect(_file), do: :unknown

  @doc """
  Whether a file's languages leave it short of `policy`.

  A show's own list is a request, so a file without its first language has a
  gap. The server default is a floor, so a file has a gap only when it carries
  none of the listed languages. That keeps an English file on a Japanese show
  under `["original", "en"]`.
  """
  @spec gap?(AudioLanguagePolicy.t() | nil, languages()) :: boolean()
  def gap?(_policy, :unknown), do: false
  def gap?(nil, _languages), do: false
  def gap?(%AudioLanguagePolicy{languages: []}, _languages), do: false

  def gap?(%AudioLanguagePolicy{source: :show} = policy, {:known, languages}),
    do: AudioLanguagePolicy.rank(policy, languages) > 0

  def gap?(%AudioLanguagePolicy{source: :server} = policy, languages),
    do: none_preferred?(policy, languages)

  @doc "Whether known `languages` carry none of `policy`'s languages."
  @spec none_preferred?(AudioLanguagePolicy.t() | nil, languages()) :: boolean()
  def none_preferred?(
        %AudioLanguagePolicy{languages: [_ | _] = preferred} = policy,
        {:known, languages}
      ),
      do: AudioLanguagePolicy.rank(policy, languages) == length(preferred)

  def none_preferred?(_policy, _languages), do: false

  @doc """
  How `candidate` compares with `current` under `policy`: `:better` when its
  rank is lower, `:worse` when higher, and `:equal` when the ranks tie, either
  side is unknown, or there is no preference to rank by.
  """
  @spec compare(AudioLanguagePolicy.t() | nil, languages(), languages()) ::
          :better | :worse | :equal
  def compare(
        %AudioLanguagePolicy{languages: [_ | _]} = policy,
        {:known, current},
        {:known, candidate}
      ) do
    current_rank = AudioLanguagePolicy.rank(policy, current)
    candidate_rank = AudioLanguagePolicy.rank(policy, candidate)

    cond do
      candidate_rank < current_rank -> :better
      candidate_rank > current_rank -> :worse
      true -> :equal
    end
  end

  def compare(_policy, _current, _candidate), do: :equal

  @doc "A plain list for event metadata: the languages, or `[]` when unknown."
  @spec to_list(languages()) :: [String.t()]
  def to_list({:known, languages}), do: languages
  def to_list(:unknown), do: []
end
