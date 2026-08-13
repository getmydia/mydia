defmodule Mydia.Streaming.AudioTrackSelector do
  @moduledoc """
  Picks which audio stream a playback should use.

  Before this module, nothing chose. The server built its ffmpeg commands with
  no `-map`, so ffmpeg applied its own implicit selection and took the audio
  stream with the most channels; the player constructed a bare media_kit
  `Player`, so mpv took whichever stream the container flagged `default`. Two
  different rules, neither of them the viewer's, and both of them wrong on the
  common dual-audio release that muxes a dub first and flags it default. That
  is why a show with an English original could open in Russian.

  Selection keys on *language*, never on a track index, for the same reason
  Plex, Jellyfin and Infuse all do: an index means nothing across two files,
  and the next episode's tracks may be in a different order.

  ## Order of decisions

  1. `prefer_default_track` short-circuits everything and returns the stream
     the container flagged, if there is one. This is the escape hatch for
     operators who tag their own files, matching Jellyfin's "Play default
     audio track regardless of language".
  2. Commentary tracks are set aside. They carry the same language tag as the
     feature, so matching on language alone would hand a viewer the
     director's commentary. They come back only if there is nothing else.
  3. Each preference is tried in order. The first one with a matching track
     wins, and ties within that language break toward the flagged track, then
     the most channels, then the earliest.
  4. Failing every preference, the container's `default` flag decides, and
     failing that, the first audio stream. So a file with nothing the viewer
     asked for still plays.

  The literal `"original"` in a preference list resolves to the item's own
  original language, which is what keeps anime in Japanese rather than
  handing over an English dub.
  """

  require Logger

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Metadata.LanguageCode

  @original "original"

  @typedoc """
  An ordered preference list, most preferred first. May contain `"original"`.
  """
  @type preferences :: [String.t()]

  @doc """
  Chooses an audio stream from `streams`, or `:none` when there is no audio.

  `streams` may contain video and subtitle streams; they are ignored. The
  returned struct's `:index` is the absolute container index ffprobe reported,
  which is what `-map 0:<index>` expects.

  ## Options

    * `:original_language` - the item's original language, used to resolve the
      `"original"` sentinel. Without it the sentinel is skipped rather than
      treated as a language named "original".
    * `:prefer_default_track` - when true, the container's `default` flag wins
      outright and `preferences` is ignored. Defaults to false.
  """
  @spec select([StreamInfo.t()], preferences(), keyword()) :: {:ok, StreamInfo.t()} | :none
  def select(streams, preferences, opts \\ []) do
    case audio_streams(streams) do
      [] ->
        :none

      audio ->
        {:ok, choose(audio, preferences, opts)}
    end
  end

  @doc """
  Chooses an audio stream for a `Mydia.Library.MediaFile`, reading its analysed
  streams and resolving `"original"` from the item's metadata.

  Returns `:none` when the file has no analysed audio streams, which is the
  case for anything scanned before stream analysis existed. Callers must treat
  that as "leave ffmpeg's implicit selection alone" rather than as an error:
  degrading to the old behaviour keeps an unanalysed file playing.

  Accepts the same options as `select/3`, except that `:original_language`
  is derived from the file when not given explicitly.
  """
  @spec select_for(struct(), preferences(), keyword()) :: {:ok, StreamInfo.t()} | :none
  def select_for(media_file, preferences, opts \\ []) do
    opts =
      Keyword.put_new_lazy(opts, :original_language, fn ->
        original_language_of(media_file)
      end)

    media_file
    |> streams_of()
    |> select(preferences, opts)
  end

  defp streams_of(%{metadata: %{streams: streams}}) when is_list(streams), do: streams
  defp streams_of(_), do: []

  # A TV media_file carries a null media_item_id and reaches its item through
  # the episode, so this must not gate on media_item alone: doing that drops
  # every episode to nil and has shipped as a bug here before. Both shapes are
  # matched, movie first.
  #
  # `%Ecto.Association.NotLoaded{}` has no :metadata or :media_item key, so an
  # unpreloaded association falls through these clauses rather than raising.
  defp original_language_of(%{media_item: %{metadata: metadata}}),
    do: LanguageCode.original_language_from(metadata)

  defp original_language_of(%{episode: %{media_item: %{metadata: metadata}}}),
    do: LanguageCode.original_language_from(metadata)

  defp original_language_of(_), do: nil

  defp choose(audio, preferences, opts) do
    if Keyword.get(opts, :prefer_default_track, false) do
      # Deliberately checked against every audio stream, commentary included:
      # an operator who turned this on is asking for the container's choice
      # verbatim, and second-guessing it here would defeat the setting.
      Enum.find(audio, &default?/1) || by_preference(audio, preferences, opts)
    else
      by_preference(audio, preferences, opts)
    end
  end

  defp by_preference(audio, preferences, opts) do
    candidates = selectable(audio)
    codes = expand(preferences, Keyword.get(opts, :original_language))

    matched(candidates, codes) || Enum.find(candidates, &default?/1) || List.first(candidates)
  end

  # Commentary is excluded from automatic selection but never from playback:
  # a file whose only audio is a commentary track still has to play, so the
  # exclusion is dropped rather than leaving the viewer with silence.
  defp selectable(audio) do
    case Enum.reject(audio, & &1.is_commentary) do
      [] -> audio
      rest -> rest
    end
  end

  # The first preference with any match wins outright. Scoring every stream
  # into one ranking, the way Jellyfin does, lets a strong tiebreak on a
  # lower-ranked language beat an exact match on a higher-ranked one; walking
  # the list in order cannot.
  defp matched(candidates, codes) do
    Enum.find_value(codes, fn code ->
      candidates
      |> Enum.filter(&LanguageCode.matches?(code, &1.language))
      |> best()
    end)
  end

  defp best([]), do: nil
  defp best([only]), do: only

  defp best(streams) do
    Enum.min_by(streams, fn stream ->
      {if(default?(stream), do: 0, else: 1), -(stream.channels || 0), stream.index || 0}
    end)
  end

  # `is_default` is nil for a stream ffprobe reported no disposition for, so
  # this cannot be a bare truthiness check on a three-valued field.
  defp default?(%StreamInfo{is_default: true}), do: true
  defp default?(_), do: false

  defp audio_streams(streams) when is_list(streams) do
    streams
    |> Enum.filter(&match?(%StreamInfo{type: :audio}, &1))
    |> Enum.sort_by(& &1.index)
  end

  defp audio_streams(_), do: []

  # Resolves the "original" sentinel and drops anything blank. An item with no
  # original language recorded simply loses that entry, falling through to the
  # next preference, which is why ["original", "en"] still yields English on a
  # film mydia has no metadata for.
  defp expand(preferences, original_language) when is_list(preferences) do
    preferences
    |> Enum.flat_map(fn
      @original -> List.wrap(presence(original_language))
      code -> List.wrap(presence(code))
    end)
    |> Enum.uniq()
  end

  defp expand(_, _), do: []

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  @doc """
  Collapses the preference sources into the one list that decides playback.

  Precedence, strongest first: the per-show preference a viewer set by picking
  a track, then the per-device preference that device carries, then the
  server's `streaming.audio_language`.

  An empty or missing list at any level means "no opinion" and defers to the
  next, rather than meaning "no preference at all". That distinction matters:
  a device that has never been configured sends `[]`, and reading that as a
  silencing override would wipe the operator's setting for every new client.
  Someone who genuinely wants no preference sets the server config to `[]`,
  which no other level then overrides.

  ## Examples

      iex> Mydia.Streaming.AudioTrackSelector.resolve_preferences(
      ...>   device: ["fr"], config: ["en"]
      ...> )
      ["fr"]

      iex> Mydia.Streaming.AudioTrackSelector.resolve_preferences(
      ...>   device: [], config: ["original", "en"]
      ...> )
      ["original", "en"]
  """
  @spec resolve_preferences(keyword()) :: preferences()
  def resolve_preferences(sources) do
    Enum.find_value([:show, :device, :config], [], fn level ->
      case Keyword.get(sources, level) do
        [_ | _] = codes -> codes
        _ -> nil
      end
    end)
  end

  @doc """
  Resolves the audio stream for a playback from a media file and the session's
  options, folding in the operator's configuration.

  This is the entry point both ffmpeg builders use, so the transcode and remux
  paths cannot drift apart on which track they pick. Returns `nil` rather than
  `:none` because callers treat "no selection" as "emit no `-map`".

  Reads `:audio_language` (the per-device preference the player sent) and
  `:show_audio_language` (the per-show preference the viewer set) from `opts`.
  """
  @spec select_for_playback(struct() | nil, keyword()) :: StreamInfo.t() | nil
  def select_for_playback(nil, _opts), do: nil

  def select_for_playback(media_file, opts) do
    {configured, prefer_default} = configured()

    preferences =
      resolve_preferences(
        show: Keyword.get(opts, :show_audio_language) || [],
        device: Keyword.get(opts, :audio_language) || [],
        config: configured
      )

    case select_for(media_file, preferences, prefer_default_track: prefer_default) do
      {:ok, stream} ->
        Logger.info(
          "Selected audio stream #{stream.index} (#{stream.language || "untagged"}, " <>
            "#{stream.codec}, #{stream.channels || "?"}ch) from preferences #{inspect(preferences)}"
        )

        stream

      :none ->
        nil
    end
  end

  @doc """
  The concrete, ordered language codes a client should hand to its own player,
  with `"original"` already resolved against this item's metadata.

  Direct play never reaches ffmpeg, so the server cannot pick the track for it;
  mpv does, and mpv needs a plain list. Resolving here rather than in the
  client keeps one implementation of the precedence rules and means the client
  needs no access to the item's original language.

  Returns `[]` when `prefer_default_audio_track` is set, which is the honest
  answer for "what language should the player insist on": none. The client
  then leaves its own selection alone and the container's flag decides, which
  is what that setting asks for.

  Every code is expanded through `LanguageCode.equivalents/1`, so `["ja"]`
  goes out as `["ja", "jpn"]`. This is not cosmetic. The list is handed
  straight to mpv's `alang`, TMDB reports original languages as ISO 639-1,
  and Matroska tags its tracks with the 3-letter forms; mpv only gained
  lenient matching between the two in 0.36, so on an older bundled libmpv a
  bare `ja` matches nothing and mpv falls back to the container's `default`
  flag, which is the dub this whole feature exists to stop selecting.
  Expanding here means the behaviour does not depend on which libmpv the
  player happens to ship.
  """
  @spec resolved_languages(struct() | nil, keyword()) :: [String.t()]
  def resolved_languages(media_file, opts \\ []) do
    case configured() do
      {_configured, true} ->
        []

      {configured, false} ->
        preferences =
          resolve_preferences(
            show: Keyword.get(opts, :show_audio_language) || [],
            device: Keyword.get(opts, :audio_language) || [],
            config: configured
          )

        original =
          Keyword.get(opts, :original_language) || original_language_of(media_file)

        preferences
        |> expand(original)
        |> Enum.flat_map(&LanguageCode.equivalents/1)
        |> Enum.uniq()
    end
  end

  @doc """
  The ffmpeg arguments that pin output stream selection to `stream`.

  Given no `-map` at all, ffmpeg applies its own implicit selection and takes
  the audio stream with the most channels, which on a dual-language release is
  routinely the 5.1 dub rather than the stereo original the viewer asked for.
  Worse, the output then holds exactly one audio track, so the player's track
  selector has nothing to switch to.

  `0:V:0` rather than `0:v:0`: the capital form skips attached pictures, so an
  embedded cover-art JPEG muxed as a video stream cannot be mistaken for the
  video track. The lowercase form would regress those files.

  Returns `[]` for `nil`, which is what a file analysed before per-stream
  metadata existed yields. Emitting no `-map` leaves ffmpeg's implicit
  selection in place, so such a file keeps playing exactly as it did before
  rather than failing.

  Both maps carry ffmpeg's trailing `?`, which makes them optional. The index
  comes from `metadata.streams`, recorded when the file was analysed, and a
  file replaced on disk without re-analysis can leave it pointing past the end
  of the real stream list. Without the `?` ffmpeg aborts with
  `Stream map '0:N' matches no streams` and the playback is simply dead, where
  before this change the same file played under implicit selection. With it,
  the worst case degrades to a stream that is missing rather than a session
  that will not start.
  """
  @spec ffmpeg_map_args(StreamInfo.t() | nil) :: [String.t()]
  def ffmpeg_map_args(%StreamInfo{index: index}) when is_integer(index) do
    ["-map", "0:V:0?", "-map", "0:#{index}?"]
  end

  def ffmpeg_map_args(_), do: []

  @doc """
  The operator's `streaming.audio_language` and `streaming.prefer_default_audio_track`,
  as `{preferences, prefer_default_track?}`.

  Read from the layered runtime config (env > DB/UI > YAML > schema defaults)
  rather than a flat `Application.get_env/3` key, for the reason
  `Mydia.Streaming.FfmpegHlsTranscoder.effective_max_height/1` documents:
  nothing explodes the resolved config struct back out to flat keys, so a flat
  read would silently ignore both `AUDIO_LANGUAGE` and the settings UI.

  Falls back to `{[], false}` when the config is unreachable, which reproduces
  the pre-existing behaviour of letting the container's flag decide.
  """
  @spec configured() :: {preferences(), boolean()}
  def configured do
    case Mydia.Config.get() do
      %{streaming: %{audio_language: languages, prefer_default_audio_track: prefer_default}} ->
        {List.wrap(languages), prefer_default == true}

      _ ->
        {[], false}
    end
  end
end
