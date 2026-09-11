defmodule MydiaWeb.LibrarySchema.EnumTypes do
  @moduledoc """
  Enum types for the Library API.

  Values mirror the atoms the contexts already use, so no resolver converts a
  client string into an atom.
  """

  use Absinthe.Schema.Notation

  @desc "Media content types"
  enum :media_type do
    value(:movie, description: "A movie")
    value(:tv_show, description: "A TV show")
  end

  @desc "Metadata providers the relay can answer from"
  enum :metadata_provider do
    value(:tmdb, description: "TMDB")
    value(:tvdb, description: "TVDB")
  end

  @desc "Whether a media item is available, arriving, or absent"
  enum :availability_state do
    value(:missing, description: "No file and nothing downloading")
    value(:partial, description: "Some episodes present")
    value(:downloaded, description: "Fully present")
    value(:downloading, description: "At least one download active")
    value(:upcoming, description: "Every episode airs in the future")
  end

  @desc "Which downloads to return"
  enum :download_filter do
    value(:all, description: "Every download row")
    value(:active, description: "Not yet imported and still moving")
    value(:completed, description: "Finished in the client, not yet imported")
    value(:imported, description: "Imported into the library")
    value(:failed, description: "Failed in the client or during import")
  end

  @desc "A download's current state"
  enum :download_status do
    value(:queued, description: "Waiting to start")
    value(:grabbing, description: "Handed to a client, no status yet")
    value(:downloading, description: "Receiving data")
    value(:checking, description: "Verifying, repairing, unpacking, or moving")
    value(:paused, description: "Manually paused")
    value(:seeding, description: "Complete and uploading")
    value(:completed, description: "Complete, not yet imported")
    value(:imported, description: "Imported into the library")
    value(:failed, description: "Terminal failure")
    value(:missing, description: "Gone from its client")
    value(:unknown, description: "Unrecognised state")
  end

  @desc "Whether a download's client configuration still exists"
  enum :client_config_state do
    value(:present, description: "Configured and enabled")
    value(:disabled, description: "Configured but disabled")
    value(:removed, description: "No longer configured")
    value(:unknown, description: "Not determined")
  end

  @desc "What a library path holds"
  enum :library_path_type do
    value(:movies, description: "Movie library")
    value(:series, description: "TV series library")
    value(:mixed, description: "Mixed content library")
  end

  @desc "Which of a show's episodes to monitor"
  enum :episode_monitoring_preset do
    value(:all, description: "Every episode")
    value(:missing, description: "Episodes without a file")
    value(:existing, description: "Episodes with a file")
    value(:future, description: "Episodes that have not aired")
    value(:none, description: "No episodes")
  end

  @desc "Which seasons of a newly added show to monitor"
  enum :season_monitoring do
    value(:all, description: "Every season")
    value(:future, description: "Only episodes that have not aired")
    value(:latest, description: "Only the latest season")
    value(:first, description: "Only the first season")
    value(:none, description: "No seasons")
  end
end
