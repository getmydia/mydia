defmodule MydiaWeb.Schema.CommonTypes do
  @moduledoc """
  Common GraphQL types shared across the schema.
  """

  use Absinthe.Schema.Notation

  @desc "Artwork URLs for a media item"
  object :artwork do
    field :poster_url, :string, description: "Poster image URL"
    field :backdrop_url, :string, description: "Backdrop/fanart image URL"
    field :thumbnail_url, :string, description: "Thumbnail image URL"
  end

  @desc "What kind of elementary stream this is"
  enum :media_stream_type do
    value(:video, description: "Video stream")
    value(:audio, description: "Audio stream")
    value(:subtitle, description: "Subtitle stream")
  end

  @desc """
  One elementary stream of a media file, as reported by ffprobe.

  Values are raw. Composing display strings ("HEVC Main 10", "7.1 (8 ch)") is
  the client's job, so the same data can be formatted differently without a
  server change. Type-specific fields are null on streams of other types.

  The disposition fields are `isDefault` / `isForced` rather than `default` /
  `forced` because `default` is a reserved word in Dart and would make the
  player's GraphQL codegen emit invalid source.
  """
  object :media_stream do
    field :index, :integer, description: "Stream index within the container"
    field :type, non_null(:media_stream_type)
    field :codec, :string, description: "Short codec name (e.g. hevc, truehd, subrip)"
    field :codec_long, :string, description: "Descriptive codec name"
    field :profile, :string, description: "Codec profile (e.g. Main 10)"
    field :level, :integer, description: "Codec level, as ffprobe's integer"
    field :language, :string, description: "ISO 639-2 language code from container tags"
    field :title, :string, description: "Track title from container tags"
    field :bitrate, :integer, description: "Stream bitrate in bits per second"

    field :is_default, :boolean
    field :is_forced, :boolean
    field :is_hearing_impaired, :boolean
    field :is_commentary, :boolean

    field :width, :integer
    field :height, :integer
    field :frame_rate, :float, description: "Average frame rate in frames per second"
    field :pixel_format, :string
    field :bit_depth, :integer
    field :color_space, :string
    field :color_transfer, :string
    field :color_primaries, :string
    field :dolby_vision_profile, :integer, description: "Dolby Vision profile, when present"
    field :aspect_ratio, :string, description: "Display aspect ratio (e.g. 16:9)"

    field :channels, :integer
    field :channel_layout, :string, description: "Channel layout (e.g. 5.1, 7.1)"
    field :sample_rate, :integer, description: "Sample rate in Hz"
  end

  @desc "A playable video file"
  object :media_file do
    field :id, non_null(:id), description: "File ID"
    field :resolution, :string, description: "Video resolution (e.g., 1080p)"
    field :codec, :string, description: "Video codec (e.g., hevc, h264)"
    field :audio_codec, :string, description: "Audio codec (e.g., dts, aac)"
    field :hdr_format, :string, description: "HDR format if applicable (e.g., dolby_vision)"
    field :size, :integer, description: "File size in bytes"
    field :bitrate, :integer, description: "Bitrate in bits per second"

    @desc "Every video, audio and subtitle stream. Null when detailed capture has not run for this file yet."
    field :streams, list_of(:media_stream) do
      resolve(fn file, _args, _info ->
        case file.metadata do
          %Mydia.Library.Structs.FileMetadata{streams: streams} when is_list(streams) ->
            {:ok, streams}

          _ ->
            {:ok, nil}
        end
      end)
    end

    @desc "File name without its directory"
    field :file_name, :string do
      resolve(fn file, _args, _info ->
        # relative_path is on the row itself, so this needs no library_path preload.
        {:ok, file.relative_path && Path.basename(file.relative_path)}
      end)
    end

    @desc "Absolute directory containing the file"
    field :directory, :string do
      resolve(fn file, _args, _info ->
        case MydiaWeb.Schema.Resolvers.MediaResolver.absolute_path(file) do
          nil -> {:ok, nil}
          path -> {:ok, Path.dirname(path)}
        end
      end)
    end

    @desc "Container format (e.g. mkv, mp4)"
    field :container, :string do
      resolve(fn file, _args, _info -> {:ok, metadata_field(file, :container)} end)
    end

    @desc "Duration in seconds"
    field :duration, :float do
      resolve(fn file, _args, _info -> {:ok, metadata_field(file, :duration)} end)
    end

    @desc "Subtitle files stored alongside the media file. Unlike `subtitles`, this never probes the file."
    field :external_subtitles, list_of(:subtitle_track) do
      resolve(fn file, _args, _info ->
        # The `url` and `content` fields both read `_media_file_id` off the
        # track map, mirroring what the `subtitles` field does.
        tracks =
          file.id
          |> Mydia.Subtitles.Extractor.list_external_subtitle_tracks()
          |> Enum.map(&Map.put(&1, :_media_file_id, file.id))

        {:ok, tracks}
      end)
    end

    @desc "Whether this file can be direct played (no transcoding needed)"
    field :direct_play_supported, :boolean do
      resolve(fn _file, _args, _info ->
        # TODO: Implement based on client capabilities
        {:ok, true}
      end)
    end

    @desc "Streaming URL for this file"
    field :stream_url, :string do
      resolve(fn file, _args, _info ->
        {:ok, "/api/v1/stream/file/#{file.id}"}
      end)
    end

    @desc "Direct play URL (no transcoding)"
    field :direct_play_url, :string do
      resolve(fn file, _args, _info ->
        {:ok, "/api/v1/stream/file/#{file.id}?strategy=DIRECT_PLAY"}
      end)
    end

    @desc "Available subtitle tracks (embedded and external)"
    field :subtitles, list_of(:subtitle_track) do
      resolve(&MydiaWeb.Schema.Resolvers.SubtitleResolver.list_subtitles/3)
    end

    @desc "Skippable segments (intro, credits). Empty when detection has not run or found nothing."
    field :segments, non_null(list_of(non_null(:media_segment))) do
      resolve(&MydiaWeb.Schema.Resolvers.MediaResolver.segments/3)
    end
  end

  @desc """
  A detected skippable segment.

  `source` and `confidence` are deliberately absent from the wire format. They
  are operator concerns, and keeping the confidence floor server side means it
  is enforced in one place rather than reimplemented in every client.
  """
  object :media_segment do
    @desc "Which kind of segment this is"
    field :type, non_null(:segment_type) do
      resolve(fn segment, _args, _info -> {:ok, String.to_existing_atom(segment.type)} end)
    end

    field :start_ms, non_null(:integer), description: "Segment start, milliseconds"
    field :end_ms, non_null(:integer), description: "Segment end, milliseconds"
  end

  @desc "User playback progress on a media item or episode"
  object :progress do
    field :position_seconds, non_null(:integer), description: "Current position in seconds"
    field :duration_seconds, :integer, description: "Total duration in seconds"
    field :percentage, :float, description: "Completion percentage (0-100)"
    field :watched, non_null(:boolean), description: "Whether marked as watched"
    field :last_watched_at, :datetime, description: "Last watched timestamp"
  end

  @desc "Input for sorting lists"
  input_object :sort_input do
    field :field, :sort_field, default_value: :title
    field :direction, :sort_direction, default_value: :asc

    @desc "Seed for the random sort. Send the same value across pages of one shuffle."
    field :seed, :integer
  end

  @desc "Pagination info for cursor-based pagination"
  object :page_info do
    field :has_next_page, non_null(:boolean)
    field :has_previous_page, non_null(:boolean)
    field :start_cursor, :string
    field :end_cursor, :string
  end

  @desc "Search result with relevance score"
  object :search_result do
    field :id, non_null(:id)
    field :type, non_null(:search_result_type)
    field :title, non_null(:string)
    field :year, :integer
    field :artwork, :artwork
    field :score, :float, description: "Relevance score: 100, 75, 50 or 25"

    field :subtitle, :string,
      description: "Parent show title for episodes, item count for collections"

    field :season_number, :integer, description: "Season number, episodes only"
    field :episode_number, :integer, description: "Episode number, episodes only"
    field :parent_id, :id, description: "Owning show ID, episodes only"
  end

  @desc "One grouped section of search results"
  object :search_section do
    field :type, non_null(:search_result_type)
    field :results, non_null(list_of(non_null(:search_result)))

    field :total_count, non_null(:integer),
      description: "True number of matches, not the length of results"
  end

  @desc "Search results container"
  object :search_results do
    field :sections, non_null(list_of(non_null(:search_section)))
    field :total_count, non_null(:integer)
  end

  @desc "A library path for organizing media"
  object :library_path do
    interface(:node)

    field :id, non_null(:id)

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :path, non_null(:string), description: "Filesystem path"
    field :type, non_null(:library_type), description: "Type of content in this library"
    field :monitored, non_null(:boolean), description: "Whether this path is actively monitored"
    field :scan_interval, :integer, description: "Scan interval in seconds"
    field :last_scan_at, :datetime, description: "Last scan timestamp"
    field :auto_organize, non_null(:boolean), description: "Whether auto-organization is enabled"
    field :auto_import, non_null(:boolean), description: "Whether auto-import is enabled"

    field :write_nfo, non_null(:boolean),
      description: "Whether NFO files are written alongside media"

    field :auto_rename, non_null(:boolean),
      description: "Whether auto-rename on import is enabled"

    @desc "Metadata provider used for TV shows in this library (tvdb or tmdb)"
    field :tv_metadata_source, :string do
      resolve(fn parent, _args, _res ->
        {:ok, parent.tv_metadata_source && to_string(parent.tv_metadata_source)}
      end)
    end
  end

  @desc "Result of toggling favorite status"
  object :toggle_favorite_result do
    field :is_favorite, non_null(:boolean), description: "New favorite status"
    field :media_item_id, non_null(:id), description: "ID of the media item"
  end

  @desc "Media access token for direct media requests"
  object :media_token do
    field :token, non_null(:string), description: "JWT token for media access"
    field :expires_at, non_null(:datetime), description: "Token expiration timestamp"

    field :permissions, non_null(list_of(non_null(:string))),
      description: "List of granted permissions"
  end

  @desc "Access token for authenticating GraphQL and API requests"
  object :access_token do
    field :token, non_null(:string), description: "JWT access token"
    field :expires_at, non_null(:datetime), description: "Token expiration timestamp"
  end

  @desc "API key for programmatic access"
  object :api_key do
    field :id, non_null(:id), description: "API key ID"
    field :name, non_null(:string), description: "User-given name"
    field :key_prefix, non_null(:string), description: "Key prefix for identification"

    field :permissions, non_null(list_of(non_null(:string))),
      description: "List of granted permissions"

    field :last_used_at, :datetime, description: "Last time the key was used"
    field :expires_at, :datetime, description: "Optional expiration timestamp"
    field :revoked_at, :datetime, description: "Revocation timestamp"
    field :inserted_at, non_null(:datetime), description: "Creation timestamp"
  end

  @desc "Result of creating an API key"
  object :create_api_key_result do
    field :api_key, non_null(:api_key), description: "The created API key"
    field :key, non_null(:string), description: "The plain API key (shown only once)"
  end

  @desc "Input for login mutation"
  input_object :login_input do
    field :username, non_null(:string), description: "Username or email"
    field :password, non_null(:string), description: "User password"
    field :device_id, non_null(:string), description: "Unique device identifier"
    field :device_name, non_null(:string), description: "Human-readable device name"
    field :platform, non_null(:string), description: "Platform (ios, android, web)"
  end

  @desc "Result of login mutation"
  object :login_result do
    field :token, non_null(:string), description: "JWT authentication token"

    field :user, non_null(:user), description: "Authenticated user information"
    field :expires_in, non_null(:integer), description: "Token expiration in seconds"
  end

  @desc "User information"
  object :user do
    field :id, non_null(:id), description: "User ID"
    field :username, :string, description: "Username"
    field :email, :string, description: "Email address"
    field :display_name, :string, description: "Display name"
  end

  @desc "A remote device paired to a user account"
  object :remote_device do
    field :id, non_null(:id), description: "Device ID"
    field :device_name, non_null(:string), description: "Human-readable device name"
    field :platform, non_null(:string), description: "Platform (ios, android, web)"
    field :last_seen_at, :datetime, description: "Last time device was active"
    field :is_revoked, non_null(:boolean), description: "Whether device has been revoked"
    field :created_at, non_null(:datetime), description: "When device was paired"
  end

  @desc "Result of revoking a device"
  object :revoke_device_result do
    field :success, non_null(:boolean), description: "Whether the revoke operation succeeded"
    field :device, :remote_device, description: "The revoked device"
  end

  @desc "A pairing claim code for device pairing"
  object :claim_code do
    field :code, non_null(:string), description: "The claim code (e.g., 'ABC-XYZ')"
    field :expires_at, non_null(:datetime), description: "When the code expires"
  end

  @desc "Remote access / P2P connection status"
  object :remote_access_status do
    field :enabled, non_null(:boolean),
      description: "Whether remote access is enabled and running"

    field :endpoint_addr, :string, description: "The node's endpoint address for sharing"
    field :connected_peers, non_null(:integer), description: "Number of connected peers"
  end

  @desc "Result of starting a streaming session"
  object :streaming_session_result do
    field :session_id, non_null(:string), description: "The HLS session identifier"
    field :duration, :float, description: "Media duration in seconds (if known)"

    field :start_position, :integer,
      description:
        "Real media position, in seconds, at which the stream begins. " <>
          "Clients must map stream-local positions by this offset. " <>
          "Absent or 0 means the stream starts at the beginning."

    field :max_bitrate, :integer,
      description:
        "Total kbps cap the server actually applied, which may be lower " <>
          "than requested on a relay connection. Null means uncapped. " <>
          "Clients should label the quality control from this, not from " <>
          "what they asked for."

    field :max_height, :integer,
      description:
        "Output height ceiling the server actually applied, which may be " <>
          "lower than requested on a relay connection. Null means the " <>
          "source resolution is preserved."
  end

  @desc "A download quality option"
  object :download_option do
    field :resolution, non_null(:string),
      description: "Resolution identifier (original, 1080p, 720p, 480p)"

    field :label, non_null(:string), description: "Human-readable label"
    field :estimated_size, non_null(:integer), description: "Estimated file size in bytes"

    field :transcode_status, :string,
      description: "Pre-transcode status: ready, transcoding, pending, or null"

    field :transcode_progress, :float, description: "Transcode progress (0.0 to 1.0)"

    field :actual_size, :integer, description: "Actual file size in bytes when transcoded"
  end

  @desc "Result of preparing a download job"
  object :prepare_download_result do
    field :job_id, non_null(:id), description: "The transcode job ID"

    field :status, non_null(:string),
      description: "Job status (pending, transcoding, ready, failed)"

    field :progress, non_null(:float), description: "Transcoding progress (0.0 to 1.0)"
    field :file_size, :integer, description: "Final file size in bytes (when ready)"
  end

  @desc "Download job status"
  object :download_job_status do
    field :job_id, non_null(:id), description: "The transcode job ID"

    field :status, non_null(:string),
      description: "Job status (pending, transcoding, ready, failed)"

    field :progress, non_null(:float), description: "Transcoding progress (0.0 to 1.0)"
    field :error, :string, description: "Error message if job failed"
    field :file_size, :integer, description: "Final file size in bytes (when ready)"
  end

  @desc "Result of cancelling a download job"
  object :cancel_download_result do
    field :success, non_null(:boolean), description: "Whether the cancellation succeeded"
  end

  @desc "A streaming candidate option"
  object :streaming_candidate do
    field :strategy, non_null(:streaming_candidate_strategy), description: "Streaming strategy"
    field :mime, non_null(:string), description: "Full MIME type with codecs parameter"
    field :container, non_null(:string), description: "Container format (mp4, ts, mkv, etc.)"
    field :video_codec, :string, description: "RFC 6381 video codec string"
    field :audio_codec, :string, description: "RFC 6381 audio codec string"
  end

  @desc "Metadata about the source media file"
  object :streaming_metadata do
    field :duration, :float, description: "Duration in seconds"
    field :width, :integer, description: "Video width in pixels"
    field :height, :integer, description: "Video height in pixels"
    field :bitrate, :integer, description: "Bitrate in bits per second"
    field :resolution, :string, description: "Resolution label (e.g., 1080p)"
    field :hdr_format, :string, description: "HDR format if applicable"
    field :original_codec, :string, description: "Original video codec"
    field :original_audio_codec, :string, description: "Original audio codec"
    field :container, :string, description: "Original container format"
  end

  @desc "Result of streaming candidates query"
  object :streaming_candidates_result do
    field :file_id, non_null(:id), description: "The resolved media file ID"

    field :candidates, non_null(list_of(non_null(:streaming_candidate))),
      description: "Prioritized list of streaming options"

    field :metadata, non_null(:streaming_metadata), description: "Source file metadata"
  end

  @desc "A subtitle track available for a media file"
  object :subtitle_track do
    @desc "Track identifier (integer for embedded, UUID for external)"
    field :track_id, non_null(:string)

    @desc "ISO 639-2 language code (e.g., 'eng', 'spa')"
    field :language, non_null(:string)

    @desc "Display title (e.g., 'English', 'Spanish (Forced)')"
    field :title, non_null(:string)

    @desc "Subtitle format (srt, vtt, ass, etc.)"
    field :format, non_null(:string)

    @desc "Whether the subtitle is embedded in the media file"
    field :embedded, non_null(:boolean)

    @desc "Whether this track can be delivered as text. False for image-based subtitles (PGS, VobSub), which play only in direct mode"
    field :deliverable, non_null(:boolean) do
      resolve(fn track, _args, _info -> {:ok, Map.get(track, :deliverable, true)} end)
    end

    @desc "Subtitle body in the requested format. Null when the track is not deliverable"
    field :content, :string do
      arg(:format, :subtitle_format, default_value: :vtt)
      resolve(&MydiaWeb.Schema.Resolvers.SubtitleResolver.content/3)
    end

    @desc "URL to download this subtitle in the requested format"
    field :url, :string do
      arg(:format, :subtitle_format, default_value: :vtt)

      resolve(fn track, args, info ->
        # Get the media_file_id from the parent context
        media_file_id = Map.get(info.source, :_media_file_id)
        format = args[:format] || :vtt
        format_str = Atom.to_string(format)

        url =
          "/api/player/v1/subtitles/file/#{media_file_id}/#{track.track_id}?format=#{format_str}"

        {:ok, url}
      end)
    end
  end

  @desc "A subtitle available from a provider, not yet downloaded"
  object :subtitle_candidate do
    @desc "Opaque signed handle. Pass to downloadSubtitle. Valid for 15 minutes"
    field :token, non_null(:string)

    @desc "ISO 639-1 language code"
    field :language, non_null(:string)

    @desc "Provider's file name for this subtitle, usually the release it matches"
    field :release_name, :string

    field :format, non_null(:string)
    field :rating, :float
    field :download_count, :integer
    field :hearing_impaired, non_null(:boolean)

    @desc "Whether the provider matched this subtitle by media file hash, the strongest signal"
    field :hash_match, non_null(:boolean)

    field :score, non_null(:integer)
    field :provider_name, non_null(:string)
  end

  @desc "Outcome of consulting one subtitle provider"
  object :subtitle_provider_status do
    field :name, non_null(:string)
    field :quota_remaining, :integer
    field :quota_total, :integer

    @desc "Null when the provider answered. A message when it did not"
    field :error, :string
  end

  @desc "Results of a subtitle search across every enabled provider"
  object :subtitle_search_payload do
    field :results, non_null(list_of(non_null(:subtitle_candidate)))
    field :providers, non_null(list_of(non_null(:subtitle_provider_status)))
  end

  defp metadata_field(%{metadata: %Mydia.Library.Structs.FileMetadata{} = metadata}, key),
    do: Map.get(metadata, key)

  defp metadata_field(_file, _key), do: nil
end
