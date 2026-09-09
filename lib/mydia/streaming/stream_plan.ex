defmodule Mydia.Streaming.StreamPlan do
  @moduledoc """
  What FFmpeg will actually do to a stream, decided once.

  Before this existed, `FfmpegHlsTranscoder.build_ffmpeg_args/3` chose `copy`
  or `libx264` from the bitrate cap while `streaming_resolver.ex` separately
  mapped the client's strategy to `:copy` or `:transcode`, and the dashboard
  displayed the resolver's answer. The two disagreed whenever a client asked
  for `HLS_COPY` at a capped rung, which is exactly what the quality selector
  does: the card showed a green "Direct Play" badge on a session re-encoding
  HEVC to H.264 at 480p.

  Everything here is a pure function of the media file and the request. The
  only environmental read is the layered config behind `effective_max_height/1`,
  and `Mydia.Config.get/0` resolves to `Application.get_env/3`
  (`lib/mydia/settings/runtime_config.ex:172`). No database, no registry, no
  port, so a plan can be asserted directly in a unit test.

  `for_hls/2` serves the HLS transcoder and may encode either stream.
  `for_remux/2` serves the fMP4 remuxer, where video is always copied by
  definition and only audio may be converted.
  """

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.AudioTrackSelector
  alias Mydia.Streaming.Compatibility
  alias Mydia.Streaming.DeviceProfile
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Args, as: AccelArgs

  # Kept in step with FfmpegHlsTranscoder's own audio budget. Only used to
  # report the audio target, never to build arguments.
  @audio_target_codec "aac"

  defmodule Video do
    @moduledoc "The video stream's fate."

    defstruct [
      :action,
      :from_codec,
      :to_codec,
      :from_width,
      :from_height,
      :to_width,
      :to_height,
      :tier
    ]

    @type t :: %__MODULE__{
            action: :copy | :encode,
            from_codec: String.t() | nil,
            to_codec: String.t() | nil,
            from_width: integer() | nil,
            from_height: integer() | nil,
            to_width: integer() | nil,
            to_height: integer() | nil,
            tier: AccelArgs.tier() | nil
          }
  end

  defmodule Audio do
    @moduledoc "The audio stream's fate, for the stream actually mapped."

    defstruct [:action, :from_codec, :to_codec, :language, :stream_index, :channels]

    @type t :: %__MODULE__{
            action: :copy | :encode,
            from_codec: String.t() | nil,
            to_codec: String.t() | nil,
            language: String.t() | nil,
            stream_index: integer() | nil,
            channels: integer() | nil
          }
  end

  defstruct [:video, :audio, :container, :max_bitrate_kbps, :accel, :selected_audio]

  @type t :: %__MODULE__{
          video: Video.t() | nil,
          audio: Audio.t() | nil,
          container: :hls_ts | :fmp4,
          max_bitrate_kbps: integer() | nil,
          accel: AccelArgs.t() | nil,
          selected_audio: StreamInfo.t() | nil
        }

  @doc """
  The plan for an HLS session, from the same opts `build_ffmpeg_args/3` reads.
  """
  @spec for_hls(Mydia.Library.MediaFile.t() | nil, keyword()) :: t()
  def for_hls(media_file, opts) do
    max_bitrate = Keyword.get(opts, :max_bitrate)
    max_height = FfmpegHlsTranscoder.effective_max_height(Keyword.get(opts, :max_height))

    video_action = hls_video_action(media_file, opts, max_bitrate, max_height)
    {from_width, from_height} = source_dimensions(media_file)

    {to_width, to_height} =
      output_dimensions(video_action, from_width, from_height, max_height)

    accel =
      case video_action do
        :copy ->
          nil

        :encode ->
          capabilities =
            Keyword.get_lazy(opts, :capabilities, fn -> HardwareAccel.capabilities() end)

          AccelArgs.build(capabilities,
            source_codec: media_file && media_file.codec,
            max_height: max_height,
            video_bitrate_kbps: video_bitrate_kbps(max_bitrate),
            crf: Keyword.get(opts, :crf, 23),
            preset: Keyword.get(opts, :preset, "medium"),
            # The caller's override, not a hardcoded literal: this branch is
            # only reached when video_action is :encode, so an explicit
            # "copy" never arrives here. Falling back to "libx264" reproduces
            # the pre-StreamPlan default for the nil case.
            video_codec: Keyword.get(opts, :video_codec) || "libx264"
          )
      end

    {audio, selected_audio} = hls_audio(media_file, opts)

    %__MODULE__{
      video: %Video{
        action: video_action,
        from_codec: media_file && media_file.codec,
        to_codec: if(video_action == :copy, do: media_file && media_file.codec, else: "h264"),
        from_width: from_width,
        from_height: from_height,
        to_width: to_width,
        to_height: to_height,
        tier: accel && accel.tier
      },
      audio: audio,
      container: :hls_ts,
      max_bitrate_kbps: max_bitrate,
      accel: accel,
      selected_audio: selected_audio
    }
  end

  @doc """
  The plan for an fMP4 remux, from the same opts `FfmpegRemuxer.build_ffmpeg_args/2` reads.

  Video is always copied: that is what REMUX means, and the strategy is only
  offered when the client already decodes the source. Audio is copied only when
  the *mapped* stream is one the caller's device profile accepts, which is a
  different question from `media_file.audio_codec`, the first stream, that the
  candidate was chosen from.
  """
  @spec for_remux(Mydia.Library.MediaFile.t() | nil, keyword()) :: t()
  def for_remux(media_file, opts) do
    {from_width, from_height} = source_dimensions(media_file)
    selected = AudioTrackSelector.select_for_playback(media_file, opts)
    from_codec = mapped_audio_codec(media_file, selected)
    action = if remux_audio_compatible?(selected, opts), do: :copy, else: :encode

    %__MODULE__{
      video: %Video{
        action: :copy,
        from_codec: media_file && media_file.codec,
        to_codec: media_file && media_file.codec,
        from_width: from_width,
        from_height: from_height,
        to_width: from_width,
        to_height: from_height,
        tier: nil
      },
      audio: build_audio(from_codec, selected, action),
      container: :fmp4,
      max_bitrate_kbps: nil,
      accel: nil,
      selected_audio: selected
    }
  end

  # No stream was selected, so no -map is emitted and ffmpeg's implicit
  # selection stands. That is the pre-existing behaviour for an unanalysed
  # file, and the codec the strategy was chosen from is the one it will pick,
  # so a blanket copy is correct there.
  defp remux_audio_compatible?(nil, _opts), do: true

  defp remux_audio_compatible?(%StreamInfo{codec: codec}, opts) do
    case Keyword.get(opts, :device_profile) do
      nil -> Compatibility.compatible_audio_codec?(codec)
      %DeviceProfile{} = profile -> Compatibility.compatible_audio_codec?(codec, profile)
    end
  end

  @doc """
  Whether the video stream will be re-encoded rather than copied.

  Height-aware, unlike the `reencodes_video?/2` it replaces. The height test is
  "does this actually reduce the source", not "is a height set": the operator's
  `MAX_TRANSCODE_HEIGHT` ceiling is folded into every request by
  `effective_max_height/1`, so the latter would turn every session on a
  configured server into an encode.

  `max_height` here must already be the **effective** height, with the
  operator's `MAX_TRANSCODE_HEIGHT` ceiling folded in: this function does not
  call `effective_max_height/1` itself and takes whatever it is given at face
  value. `for_hls/2` applies `effective_max_height/1` before calling in; any
  other caller must do the same, or a configured ceiling will silently stop
  applying to this decision.
  """
  @spec encodes_video?(Mydia.Library.MediaFile.t() | nil, integer() | nil, integer() | nil) ::
          boolean()
  def encodes_video?(media_file, max_bitrate, max_height) do
    cond do
      not is_nil(max_bitrate) -> true
      transcode_policy() != :copy_when_compatible -> true
      is_nil(media_file) -> true
      downscaling?(media_file, max_height) -> true
      true -> not copyable_video_codec?(media_file.codec)
    end
  end

  @doc """
  The source's pixel dimensions, `{width, height}`, either element possibly nil.

  Reads `metadata.streams` first, per `lib/mydia/streaming/README.md`: the flat
  `FileMetadata` fields are a fallback for rows written before per-stream
  capture, and some rows have neither.
  """
  @spec source_dimensions(Mydia.Library.MediaFile.t() | nil) ::
          {integer() | nil, integer() | nil}
  def source_dimensions(nil), do: {nil, nil}

  def source_dimensions(%{metadata: nil}), do: {nil, nil}

  def source_dimensions(%{metadata: metadata}) do
    case video_stream(metadata) do
      %StreamInfo{width: w, height: h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> {metadata.width, metadata.height}
    end
  end

  @doc "H.264 is the only video codec every target can decode untouched."
  @spec copyable_video_codec?(String.t() | nil) :: boolean()
  def copyable_video_codec?(nil), do: false

  def copyable_video_codec?(codec) when is_binary(codec) do
    String.downcase(codec) in ["h264", "avc", "avc1"]
  end

  @doc "AAC is the only audio codec every browser can decode untouched."
  @spec copyable_audio_codec?(String.t() | nil) :: boolean()
  def copyable_audio_codec?(nil), do: false

  def copyable_audio_codec?(codec) when is_binary(codec) do
    String.downcase(codec) in ["aac", "mp4a"]
  end

  ## Internals

  defp hls_video_action(media_file, opts, max_bitrate, max_height) do
    case Keyword.get(opts, :video_codec) do
      "copy" -> :copy
      nil -> if encodes_video?(media_file, max_bitrate, max_height), do: :encode, else: :copy
      _explicit -> :encode
    end
  end

  defp hls_audio(media_file, opts) do
    selected = AudioTrackSelector.select_for_playback(media_file, opts)
    from_codec = mapped_audio_codec(media_file, selected)

    action =
      case Keyword.get(opts, :audio_codec) do
        "copy" ->
          :copy

        nil ->
          if not is_nil(media_file) and transcode_policy() == :copy_when_compatible and
               copyable_audio_codec?(from_codec) do
            :copy
          else
            :encode
          end

        _explicit ->
          :encode
      end

    {build_audio(from_codec, selected, action), selected}
  end

  # The mapped stream's codec, or `media_file.audio_codec` (the *first*
  # audio stream, the one that chose the candidate strategy) when nothing
  # was selected: no analysed streams at all, or no match among them. Shared
  # by for_hls/2 and for_remux/2 so the fallback rule cannot drift between
  # the two ffmpeg paths.
  defp mapped_audio_codec(media_file, selected) do
    case selected do
      %StreamInfo{codec: codec} when is_binary(codec) -> codec
      _ -> media_file && media_file.audio_codec
    end
  end

  # The reported Audio struct for the stream actually mapped. Shared by
  # for_hls/2 and for_remux/2, which only disagree on how `action` itself is
  # decided; from_codec must already be `mapped_audio_codec/2`'s answer.
  defp build_audio(from_codec, selected, action) do
    %Audio{
      action: action,
      from_codec: from_codec,
      to_codec: if(action == :copy, do: from_codec, else: @audio_target_codec),
      language: selected && selected.language,
      stream_index: selected && selected.index,
      channels: selected && selected.channels
    }
  end

  # Mirrors FfmpegHlsTranscoder.reencodes_video?/2 and build_ffmpeg_args/3,
  # which each read this flat key independently rather than through the
  # layered Mydia.Config; see config/config.exs's :mydia, :streaming default.
  defp transcode_policy do
    Application.get_env(:mydia, :streaming, [])
    |> Keyword.get(:transcode_policy, :copy_when_compatible)
  end

  defp video_stream(%{streams: streams}) when is_list(streams) do
    Enum.find(streams, fn
      %StreamInfo{type: :video} -> true
      _ -> false
    end)
  end

  defp video_stream(_metadata), do: nil

  defp downscaling?(_media_file, nil), do: false

  defp downscaling?(media_file, height) do
    case source_dimensions(media_file) do
      {_width, source_height} when is_integer(source_height) -> height < source_height
      _ -> false
    end
  end

  # A copy never changes geometry. An encode is bounded by the requested
  # ceiling, and the scale filter rounds the height down to even
  # (2*trunc(min(h,ih)/2), mirrored by `even_floor/1`) and derives width from
  # the aspect ratio via `-2`, so reporting the requested number verbatim
  # would name a resolution FFmpeg never wrote.
  defp output_dimensions(:copy, from_width, from_height, _max_height) do
    {from_width, from_height}
  end

  defp output_dimensions(:encode, from_width, from_height, max_height) do
    cond do
      is_nil(from_height) ->
        {from_width, nil}

      is_nil(max_height) or max_height >= from_height ->
        {from_width, even_floor(from_height)}

      true ->
        height = even_floor(max_height)
        {scaled_width(from_width, from_height, height), height}
    end
  end

  defp scaled_width(nil, _from_height, _height), do: nil

  defp scaled_width(from_width, from_height, height) do
    round_even(from_width * height / from_height)
  end

  # Floors to the nearest even integer, matching AccelArgs.height_expression/1's
  # `2*trunc(min(h,ih)/2)`: that is the actual filter FFmpeg runs, so the
  # reported height must match it exactly rather than merely approximate it.
  defp even_floor(value) when is_integer(value), do: 2 * div(value, 2)

  # Rounds to the nearest even integer. There is no FFmpeg expression to
  # mirror here: the `-2` scale parameter computes the output width live from
  # whatever height the filter lands on, so this is only ever an estimate for
  # the dashboard. Flooring (as `even_floor/1` does for height, where FFmpeg's
  # own truncating expression must be matched exactly) would round every
  # fractional pixel down and habitually undershoot the true output width.
  defp round_even(value) do
    2 * round(value / 2)
  end

  # Mirrors FfmpegHlsTranscoder's ABR split: the audio budget comes out of the
  # total cap before the video encoder sees it.
  defp video_bitrate_kbps(nil), do: nil
  defp video_bitrate_kbps(max_bitrate), do: max(max_bitrate - 128, 100)
end
