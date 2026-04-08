defmodule Mydia.Downloads.Download do
  @moduledoc """
  Schema for download queue items.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          indexer: String.t() | nil,
          title: String.t() | nil,
          download_url: String.t() | nil,
          download_client: String.t() | nil,
          download_client_id: String.t() | nil,
          completed_at: DateTime.t() | nil,
          error_message: String.t() | nil,
          metadata: map() | nil,
          match_status: String.t() | nil,
          imported_at: DateTime.t() | nil,
          import_retry_count: integer(),
          import_last_error: String.t() | nil,
          import_next_retry_at: DateTime.t() | nil,
          import_failed_at: DateTime.t() | nil,
          save_path: String.t() | nil,
          media_item: Mydia.Media.MediaItem.t() | Ecto.Association.NotLoaded.t(),
          episode: Mydia.Media.Episode.t() | nil | Ecto.Association.NotLoaded.t(),
          library_path: Mydia.Settings.LibraryPath.t() | nil | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "downloads" do
    field :indexer, :string
    field :title, :string
    field :download_url, :string
    field :download_client, :string
    field :download_client_id, :string
    field :completed_at, :utc_datetime
    field :error_message, :string
    field :metadata, Mydia.Settings.JsonMapType
    field :match_status, :string

    # Import tracking fields
    field :imported_at, :utc_datetime
    field :import_retry_count, :integer, default: 0
    field :import_last_error, :string
    field :import_next_retry_at, :utc_datetime
    field :import_failed_at, :utc_datetime
    field :save_path, :string

    belongs_to :media_item, Mydia.Media.MediaItem
    belongs_to :episode, Mydia.Media.Episode

    # For specialized library downloads (music, books, adult) that don't have
    # a media_item, this field indicates which library to import files to
    belongs_to :library_path, Mydia.Settings.LibraryPath

    timestamps(type: :utc_datetime, updated_at: :updated_at)
  end

  @doc """
  Changeset for creating or updating a download.
  """
  def changeset(download, attrs) do
    download
    |> cast(attrs, [
      :media_item_id,
      :episode_id,
      :library_path_id,
      :indexer,
      :title,
      :download_url,
      :download_client,
      :download_client_id,
      :completed_at,
      :error_message,
      :metadata,
      :match_status,
      :imported_at,
      :import_retry_count,
      :import_last_error,
      :import_next_retry_at,
      :import_failed_at,
      :save_path
    ])
    |> validate_required([:title])
    |> validate_inclusion(:match_status, ["unmatched", "unresolved_files"])
    |> foreign_key_constraint(:media_item_id)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:library_path_id)
    |> unique_constraint([:download_client, :download_client_id],
      message: "download already exists for this torrent"
    )
  end
end
