defmodule Mydia.Streaming.Candidates do
  @moduledoc """
  Shared logic for building streaming candidates and metadata responses.

  Used by both the REST StreamController and the GraphQL StreamingResolver
  to provide consistent candidate lists for media files.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{FileAnalyzer, FileRanking, Hdr, MediaFile}
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo
  alias Mydia.Streaming.{AudioPreferences, AudioTrackSelector, CodecString, Compatibility}

  @default_max_attempts 3

  @doc """
  Resolves a media file from a content_type and id.

  Returns `{:ok, media_file}` or `{:error, reason}`.
  """
  def resolve_media_file(content_type, id) do
    active_files_query =
      from(mf in MediaFile, where: is_nil(mf.trashed_at), preload: :library_path)

    case content_type do
      "movie" ->
        try do
          media_item =
            Mydia.Media.get_media_item!(id, preload: [media_files: active_files_query])

          case FileRanking.best(media_item.media_files) do
            nil -> {:error, :no_media_files}
            media_file -> {:ok, media_file}
          end
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
          Ecto.Query.CastError -> {:error, :not_found}
        end

      "episode" ->
        try do
          episode = Mydia.Media.get_episode!(id, preload: [media_files: active_files_query])

          case FileRanking.best(episode.media_files) do
            nil -> {:error, :no_media_files}
            media_file -> {:ok, media_file}
          end
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
          Ecto.Query.CastError -> {:error, :not_found}
        end

      "file" ->
        try do
          # A trashed file is not a streaming candidate, same as the "movie"
          # and "episode" clauses above. Without this, a quality upgrade that
          # trashes the old file (Mydia.Upgrades.apply_upgrade/4) would leave
          # a dead file id resolvable here, so the player's self-heal (which
          # relies on this returning :not_found) would never fire.
          media_file = Repo.get!(active_files_query, id)
          {:ok, media_file}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
          Ecto.Query.CastError -> {:error, :not_found}
        end

      _ ->
        {:error, :invalid_content_type}
    end
  end

  @doc """
  Ensures codec info is present on a media file, extracting on-the-fly if needed.
  """
  def ensure_codec_info(media_file) do
    absolute_path = MediaFile.absolute_path(media_file)

    if absolute_path && File.exists?(absolute_path) do
      maybe_extract_codec_info(media_file, absolute_path)
    else
      media_file
    end
  end

  @doc """
  Builds a prioritized list of streaming candidates for a media file.
  """
  def build_streaming_candidates(media_file) do
    compatibility = Compatibility.check_compatibility(media_file)
    metadata = media_file.metadata || FileMetadata.empty()

    video_codec_str = CodecString.video_codec_string(media_file.codec, metadata)
    audio_codec_str = CodecString.audio_codec_string(media_file.audio_codec, metadata)
    video_variants = CodecString.video_codec_variants(media_file.codec, metadata)

    case compatibility do
      :direct_play ->
        container = Compatibility.get_container_format(media_file)

        [
          build_candidate("DIRECT_PLAY", container, video_codec_str, audio_codec_str),
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")
        ]

      :needs_remux ->
        [
          build_candidate("REMUX", "mp4", video_codec_str, audio_codec_str),
          build_candidate("HLS_COPY", "ts", video_codec_str, audio_codec_str),
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")
        ]

      :needs_transcoding ->
        native_candidates =
          Enum.map(video_variants, fn video_variant ->
            build_candidate("HLS_COPY", "ts", video_variant, audio_codec_str)
          end)

        transcode_candidate =
          build_candidate("TRANSCODE", "ts", "avc1.640028", "mp4a.40.2")

        native_candidates ++ [transcode_candidate]
    end
  end

  @doc """
  Builds metadata response for a media file.
  """
  def build_metadata_response(media_file, opts \\ []) do
    metadata = media_file.metadata || FileMetadata.empty()
    with_item = with_item_metadata(media_file)

    # The viewer's own choice for this show, if they made one. Passed as the
    # strongest preference level so a picked language survives to the next
    # episode, including on direct play, where the server never sees the
    # track selection itself.
    show_preference =
      AudioPreferences.for_media_file(Keyword.get(opts, :user_id), with_item)

    # hdr_format must be the display string ("HDR10", "Dolby Vision", "HLG"),
    # never the raw Ecto.Enum atom (hdr10, dolby_vision). Self-hosted installs
    # have no coordinated deploy order, so a shipped player reaching this
    # server months from now still expects display text here. This map backs
    # both this REST candidates payload and the GraphQL streamingMetadata
    # object (see MydiaWeb.Schema.Resolvers.StreamingResolver.streaming_candidates/3),
    # so fixing it here fixes both wire paths at once.
    hdr = %Hdr{
      base: media_file.hdr_format,
      dv_profile: media_file.dolby_vision_profile,
      bl_compat_id: media_file.dolby_vision_bl_compat_id
    }

    %{
      duration: metadata.duration,
      width: metadata.width,
      height: metadata.height,
      bitrate: media_file.bitrate,
      resolution: media_file.resolution,
      hdr_format: Hdr.display(hdr),
      dolby_vision_profile: media_file.dolby_vision_profile,
      dolby_vision_bl_compat_id: media_file.dolby_vision_bl_compat_id,
      original_codec: media_file.codec,
      original_audio_codec: media_file.audio_codec,
      container: metadata.container,
      preferred_audio_languages:
        AudioTrackSelector.resolved_languages(with_item,
          show_audio_language: show_preference
        )
    }
  end

  # resolve_media_file/2 preloads only :library_path, so the item this file
  # belongs to is absent here and the "original" audio preference would
  # silently resolve to nothing. Preloading is a no-op for the associations
  # already loaded, and this runs once per candidates request on a path that
  # already makes several queries.
  #
  # `episode: :media_item` is the half that matters: a TV media_file carries a
  # null media_item_id and reaches its item only through the episode.
  defp with_item_metadata(media_file) do
    Repo.preload(media_file, [:media_item, episode: :media_item])
  end

  defp build_candidate(strategy, container, video_codec, audio_codec) do
    mime = CodecString.build_mime_type(container, video_codec, audio_codec)

    %{
      strategy: strategy,
      mime: mime,
      container: container,
      video_codec: video_codec,
      audio_codec: audio_codec
    }
  end

  defp maybe_extract_codec_info(%MediaFile{analyzed_at: nil} = media_file, absolute_path) do
    max_attempts = Application.get_env(:mydia, :file_analysis_max_attempts, @default_max_attempts)

    if media_file.analysis_attempts < max_attempts do
      result = FileAnalyzer.analyze(absolute_path)

      case Library.apply_analysis(media_file, result) do
        outcome when outcome in [:ok, :already_analyzed] ->
          Repo.get!(MediaFile, media_file.id) |> Repo.preload(:library_path)

        {:error, reason} ->
          Logger.warning("Lazy ffprobe analysis failed",
            file_id: media_file.id,
            reason: inspect(reason)
          )

          media_file
      end
    else
      # Attempt ceiling already hit; do not retry forever on every play.
      media_file
    end
  end

  defp maybe_extract_codec_info(media_file, absolute_path) do
    metadata = media_file.metadata || FileMetadata.empty()

    case metadata.duration do
      nil ->
        case Mydia.Library.ThumbnailGenerator.get_duration(absolute_path) do
          {:ok, duration} ->
            updated_metadata = %{metadata | duration: duration}

            spawn(fn ->
              Mydia.Library.update_media_file_scan(media_file, %{metadata: updated_metadata})
            end)

            %{media_file | metadata: updated_metadata}

          {:error, _reason} ->
            media_file
        end

      _duration ->
        media_file
    end
  end
end
