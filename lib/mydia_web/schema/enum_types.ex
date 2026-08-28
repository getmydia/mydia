defmodule MydiaWeb.Schema.EnumTypes do
  @moduledoc """
  GraphQL enum type definitions.
  """

  use Absinthe.Schema.Notation

  @desc "Media content types"
  enum :media_type do
    value(:movie, description: "A movie")
    value(:tv_show, description: "A TV show")
    value(:episode, description: "A TV episode")
  end

  @desc "Library search result types"
  enum :search_result_type do
    value(:movie, description: "A movie")
    value(:tv_show, description: "A TV show")
    value(:episode, description: "A TV episode")
    value(:collection, description: "A user collection")
  end

  @desc "Library path type"
  enum :library_type do
    value(:movies, description: "Movie library")
    value(:series, description: "TV series library")
    value(:mixed, description: "Mixed content library")
  end

  @desc "Sort field for media lists"
  enum :sort_field do
    value(:title, description: "Sort by title")
    value(:added_at, description: "Sort by date added")
    value(:year, description: "Sort by year")
    value(:rating, description: "Sort by rating")
    value(:runtime, description: "Sort by duration")
    value(:popularity, description: "Sort by popularity")
    value(:content_rating, description: "Sort by content rating")
    value(:release_date, description: "Sort by release date")
    value(:random, description: "Shuffle, stable for a given seed")
    value(:last_played, description: "Sort by when the viewer last watched it")
    value(:watch_state, description: "Sort by watched state; ascending puts unwatched first")
  end

  @desc "Sort direction"
  enum :sort_direction do
    value(:asc, description: "Ascending order")
    value(:desc, description: "Descending order")
  end

  @desc "Media category (auto-classified or user-override)"
  enum :media_category do
    value(:movie, description: "Standard movie")
    value(:anime_movie, description: "Anime movie")
    value(:cartoon_movie, description: "Animated/cartoon movie")
    value(:tv_show, description: "Standard TV show")
    value(:anime_series, description: "Anime series")
    value(:cartoon_series, description: "Animated/cartoon series")
  end

  @desc "Subtitle format"
  enum :subtitle_format do
    value(:srt, description: "SubRip Text")
    value(:vtt, description: "WebVTT")
    value(:ass, description: "Advanced SubStation Alpha")
    value(:ssa, description: "SubStation Alpha")
    value(:pgs, description: "Presentation Graphic Stream (image-based)")
    value(:vobsub, description: "VobSub (image-based)")
    value(:unknown, description: "Unknown format")
  end

  @desc "Streaming strategy for HLS sessions"
  enum :streaming_strategy do
    value(:hls_copy, description: "HLS with stream copy (no transcoding)")
    value(:transcode, description: "Full transcoding to HLS")
  end

  @desc "Streaming candidate strategy (includes all possible strategies)"
  enum :streaming_candidate_strategy do
    value(:direct_play, description: "Direct file playback (no processing)")
    value(:remux, description: "Container remux (no re-encoding)")
    value(:hls_copy, description: "HLS with stream copy")
    value(:transcode, description: "Full transcoding")
  end

  @desc "A region of a media file a viewer may want to skip"
  enum :segment_type do
    value(:intro, description: "Opening theme")
    value(:credits, description: "Closing credits")
  end

  @desc "Whether a calendar entry is an episode or a movie"
  enum :calendar_entry_kind do
    value(:episode, description: "A TV episode, dated by its air date")
    value(:movie, description: "A movie, dated by its release date")
  end
end
