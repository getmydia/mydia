defmodule MydiaWeb.Schema.MutationTypes do
  @moduledoc """
  GraphQL mutation type definitions.
  """

  use Absinthe.Schema.Notation

  alias MydiaWeb.Schema.Resolvers.PlaybackResolver
  alias MydiaWeb.Schema.Resolvers.RemoteAccessResolver
  alias MydiaWeb.Schema.Resolvers.ApiKeyResolver
  alias MydiaWeb.Schema.Resolvers.StreamingResolver
  alias MydiaWeb.Schema.Resolvers.DownloadResolver
  alias MydiaWeb.Schema.Resolvers.SubtitleSearchResolver

  object :playback_mutations do
    @desc "Update playback progress for a movie"
    field :update_movie_progress, :progress do
      arg(:movie_id, non_null(:id))
      arg(:position_seconds, non_null(:integer))
      arg(:duration_seconds, :integer)
      resolve(&PlaybackResolver.update_movie_progress/3)
    end

    @desc "Update playback progress for an episode"
    field :update_episode_progress, :progress do
      arg(:episode_id, non_null(:id))
      arg(:position_seconds, non_null(:integer))
      arg(:duration_seconds, :integer)
      resolve(&PlaybackResolver.update_episode_progress/3)
    end

    @desc "Mark a movie as watched"
    field :mark_movie_watched, :movie do
      arg(:movie_id, non_null(:id))
      resolve(&PlaybackResolver.mark_movie_watched/3)
    end

    @desc "Mark a movie as unwatched"
    field :mark_movie_unwatched, :movie do
      arg(:movie_id, non_null(:id))
      resolve(&PlaybackResolver.mark_movie_unwatched/3)
    end

    @desc "Mark an episode as watched"
    field :mark_episode_watched, :episode do
      arg(:episode_id, non_null(:id))
      resolve(&PlaybackResolver.mark_episode_watched/3)
    end

    @desc "Mark an episode as unwatched"
    field :mark_episode_unwatched, :episode do
      arg(:episode_id, non_null(:id))
      resolve(&PlaybackResolver.mark_episode_unwatched/3)
    end

    @desc "Mark all episodes in a season as watched"
    field :mark_season_watched, :tv_show do
      arg(:show_id, non_null(:id))
      arg(:season_number, non_null(:integer))
      resolve(&PlaybackResolver.mark_season_watched/3)
    end

    @desc "Mark all episodes in a season as unwatched"
    field :mark_season_unwatched, :tv_show do
      arg(:show_id, non_null(:id))
      arg(:season_number, non_null(:integer))
      resolve(&PlaybackResolver.mark_season_unwatched/3)
    end

    @desc "Mark an episode and all earlier episodes in its season as watched"
    field :mark_episodes_up_to_watched, :tv_show do
      arg(:episode_id, non_null(:id))
      resolve(&PlaybackResolver.mark_episodes_up_to_watched/3)
    end

    @desc "Toggle favorite status for a media item"
    field :toggle_favorite, :toggle_favorite_result do
      arg(:media_item_id, non_null(:id))
      resolve(&PlaybackResolver.toggle_favorite/3)
    end

    @desc "Hide a movie or show from Continue Watching until it is played again"
    field :remove_from_continue_watching, :remove_from_continue_watching_result do
      arg(:media_item_id, non_null(:id))
      resolve(&PlaybackResolver.remove_from_continue_watching/3)
    end
  end

  object :remote_access_mutations do
    @desc "Refresh a media access token before it expires"
    field :refresh_media_token, :media_token do
      arg(:token, non_null(:string))
      resolve(&RemoteAccessResolver.refresh_media_token/3)
    end

    @desc "Exchange a pairing device token for a fresh access token"
    field :refresh_access_token, :access_token do
      arg(:device_token, non_null(:string))
      resolve(&RemoteAccessResolver.refresh_access_token/3)
    end

    @desc "Generate a pairing claim code for device pairing (requires authentication)"
    field :generate_claim_code, :claim_code do
      resolve(&RemoteAccessResolver.generate_claim_code/3)
    end
  end

  object :api_key_mutations do
    @desc "Create a new API key for the current user"
    field :create_api_key, :create_api_key_result do
      arg(:name, non_null(:string))
      arg(:permissions, list_of(non_null(:string)))
      arg(:expires_at, :datetime)
      resolve(&ApiKeyResolver.create_api_key/3)
    end

    @desc "Revoke an API key"
    field :revoke_api_key, :api_key do
      arg(:id, non_null(:id))
      resolve(&ApiKeyResolver.revoke_api_key/3)
    end

    @desc "Delete an API key"
    field :delete_api_key, :boolean do
      arg(:id, non_null(:id))
      resolve(&ApiKeyResolver.delete_api_key/3)
    end
  end

  object :auth_mutations do
    @desc "Login with username/password and device information"
    field :login, :login_result do
      arg(:input, non_null(:login_input))
      resolve(&MydiaWeb.Schema.Resolvers.AuthResolver.login/3)
    end
  end

  object :device_mutations do
    @desc "Revoke a device"
    field :revoke_device, :revoke_device_result do
      arg(:id, non_null(:id))
      resolve(&MydiaWeb.Schema.Resolvers.DeviceResolver.revoke_device/3)
    end
  end

  object :streaming_mutations do
    @desc "Start an HLS streaming session for a media file"
    field :start_streaming_session, :streaming_session_result do
      arg(:file_id, non_null(:id))
      arg(:strategy, non_null(:streaming_strategy))
      arg(:max_bitrate, :integer, description: "Total kbps cap (video + audio), e.g. 2000")

      arg(:max_height, :integer,
        description: "Output height ceiling in pixels, e.g. 720. Preserves aspect ratio"
      )

      arg(:start_position, :integer,
        description:
          "Real media position, in seconds, at which to begin transcoding. " <>
            "Optional; omitted or 0 starts at the beginning."
      )

      resolve(&StreamingResolver.start_streaming_session/3)
    end

    @desc "Remember which audio language this viewer wants for a show or film"
    field :set_audio_language_preference, :audio_language_preference_result do
      arg(:file_id, non_null(:id),
        description:
          "Any file of the show or film. The preference is stored against the " <>
            "item it belongs to, so a choice made on one episode applies to the rest."
      )

      arg(:language, :string,
        description:
          "Language code to remember, e.g. \"eng\". Null forgets the choice and " <>
            "returns this item to the device and server defaults."
      )

      resolve(&StreamingResolver.set_audio_language_preference/3)
    end

    @desc "End an HLS streaming session"
    field :end_streaming_session, :boolean do
      arg(:session_id, non_null(:string))
      resolve(&StreamingResolver.end_streaming_session/3)
    end
  end

  object :download_mutations do
    @desc "Get available download quality options for a media item"
    field :download_options, list_of(non_null(:download_option)) do
      arg(:content_type, non_null(:string), description: "Content type: 'movie' or 'episode'")

      arg(:id, non_null(:id),
        description: "Media item ID (for movie) or Episode ID (for episode)"
      )

      resolve(&DownloadResolver.download_options/3)
    end

    @desc "Start or return existing transcode job for download"
    field :prepare_download, :prepare_download_result do
      arg(:content_type, non_null(:string), description: "Content type: 'movie' or 'episode'")

      arg(:id, non_null(:id),
        description: "Media item ID (for movie) or Episode ID (for episode)"
      )

      arg(:resolution, :string, default_value: "720p", description: "Target resolution")
      resolve(&DownloadResolver.prepare_download/3)
    end

    @desc "Get current status and progress of a transcode job"
    field :download_job_status, :download_job_status do
      arg(:job_id, non_null(:id), description: "The transcode job ID")
      resolve(&DownloadResolver.job_status/3)
    end

    @desc "Cancel a transcode job"
    field :cancel_download_job, :cancel_download_result do
      arg(:job_id, non_null(:id), description: "The transcode job ID")
      resolve(&DownloadResolver.cancel_job/3)
    end
  end

  object :subtitle_mutations do
    @desc "Download a subtitle candidate returned by subtitleSearch"
    field :download_subtitle, non_null(:subtitle_track) do
      arg(:media_file_id, non_null(:id))
      arg(:token, non_null(:string))
      resolve(&SubtitleSearchResolver.download/3)
    end
  end
end
