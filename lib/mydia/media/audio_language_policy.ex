defmodule Mydia.Media.AudioLanguagePolicy do
  @moduledoc """
  The ordered audio languages a media item's releases are ranked against, and
  where that list came from.

  A show may carry its own list in `media_items.audio_languages`. Without one,
  the operator's `streaming.audio_language` applies, the same setting playback
  reads. The sentinel `"original"` resolves to the item's original language,
  which is what keeps a Japanese show Japanese-first under the default
  `["original", "en"]` while an English-first override still prefers a dub.

  `new/3`, `rank/2`, `matches/2` and `event_fields/1` are pure.

  ## Rank

  A release's rank is the position of the first preferred language it carries,
  or the length of the list when it carries none, so lower is better. Matches
  counts how many preferred languages it carries, which breaks ties in favour
  of dual audio. An empty list, or no policy at all, ranks every release 0,
  which leaves ranking exactly as it was before languages were considered.
  """

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.LanguageCode

  @original "original"

  @enforce_keys [:languages, :source]
  defstruct [:languages, :source, :original_language]

  @type source :: :show | :server

  @type t :: %__MODULE__{
          languages: [String.t()],
          source: source(),
          original_language: String.t() | nil
        }

  @doc """
  Builds a policy from a raw preference list, resolving `"original"` against
  `original_language` and reducing every code to its canonical form.
  """
  @spec new([String.t() | nil], source(), String.t() | nil) :: t()
  def new(languages, source, original_language) when source in [:show, :server] do
    original = LanguageCode.canonical(original_language)

    resolved =
      languages
      |> List.wrap()
      |> Enum.flat_map(&resolve(&1, original))
      |> Enum.uniq()

    %__MODULE__{languages: resolved, source: source, original_language: original}
  end

  @doc """
  The policy that governs `media_item`: its own override when set, otherwise the
  server list. Pass `server_languages:` to avoid reading the runtime config
  (tests, or a caller that already holds it).
  """
  @spec effective(MediaItem.t(), keyword()) :: t()
  def effective(%MediaItem{} = media_item, opts \\ []) do
    original = LanguageCode.original_language_from(media_item.metadata)

    case media_item.audio_languages do
      [_ | _] = languages ->
        new(languages, :show, original)

      _ ->
        languages = Keyword.get_lazy(opts, :server_languages, &server_languages/0)
        new(languages, :server, original)
    end
  end

  @doc """
  `streaming.audio_language` from the layered runtime config, the list playback
  already honours. Read through `Mydia.Config.get/0` rather than a flat
  application env key, for the reason `Mydia.Streaming.AudioTrackSelector.configured/0`
  documents.
  """
  @spec server_languages() :: [String.t()]
  def server_languages do
    case Mydia.Config.get() do
      %{streaming: %{audio_language: languages}} -> List.wrap(languages)
      _ -> []
    end
  end

  @doc "Position of the best preferred language in `languages`. Lower is better."
  @spec rank(t() | nil, [String.t()]) :: non_neg_integer()
  def rank(nil, _languages), do: 0
  def rank(%__MODULE__{languages: []}, _languages), do: 0

  def rank(%__MODULE__{languages: preferred}, languages) do
    Enum.find_index(preferred, &(&1 in languages)) || length(preferred)
  end

  @doc "How many preferred languages `languages` carries."
  @spec matches(t() | nil, [String.t()]) :: non_neg_integer()
  def matches(nil, _languages), do: 0

  def matches(%__MODULE__{languages: preferred}, languages),
    do: Enum.count(preferred, &(&1 in languages))

  @doc "The fields a search event records so Activity can show which list applied."
  @spec event_fields(t() | nil) :: map()
  def event_fields(nil), do: %{}

  def event_fields(%__MODULE__{languages: languages, source: source}) do
    %{"audio_preference" => languages, "audio_preference_source" => Atom.to_string(source)}
  end

  defp resolve(@original, nil), do: []
  defp resolve(@original, original), do: [original]

  defp resolve(code, _original) when is_binary(code) do
    case LanguageCode.canonical(code) do
      nil -> []
      canonical -> [canonical]
    end
  end

  defp resolve(_code, _original), do: []
end
