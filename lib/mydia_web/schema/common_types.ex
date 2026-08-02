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

  @desc "A playable video file"
  object :media_file do
    field :id, non_null(:id), description: "File ID"
    field :resolution, :string, description: "Video resolution (e.g., 1080p)"
    field :codec, :string, description: "Video codec (e.g., hevc, h264)"
    field :audio_codec, :string, description: "Audio codec (e.g., dts, aac)"
    field :hdr_format, :string, description: "HDR format if applicable (e.g., dolby_vision)"
    field :size, :integer, description: "File size in bytes"
    field :bitrate, :integer, description: "Bitrate in bits per second"

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
end
