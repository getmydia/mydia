defmodule Mydia.Media.MediaRequest do
  @moduledoc """
  Schema for media requests submitted by guest users requiring admin approval.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          media_type: String.t() | nil,
          title: String.t() | nil,
          original_title: String.t() | nil,
          year: integer() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          imdb_id: String.t() | nil,
          poster_path: String.t() | nil,
          status: String.t(),
          requester_notes: String.t() | nil,
          admin_notes: String.t() | nil,
          rejection_reason: String.t() | nil,
          approved_at: DateTime.t() | nil,
          rejected_at: DateTime.t() | nil,
          requester: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          approved_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          media_item: Mydia.Media.MediaItem.t() | nil | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @status_values ~w(pending approved rejected)
  @media_types ~w(movie tv_show)

  schema "media_requests" do
    field :media_type, :string
    field :title, :string
    field :original_title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string
    field :poster_path, :string
    field :status, :string, default: "pending"
    field :requester_notes, :string
    field :admin_notes, :string
    field :rejection_reason, :string
    field :approved_at, :utc_datetime
    field :rejected_at, :utc_datetime

    belongs_to :requester, Mydia.Accounts.User
    belongs_to :approved_by, Mydia.Accounts.User
    belongs_to :media_item, Mydia.Media.MediaItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new media request.
  """
  def create_changeset(media_request, attrs) do
    media_request
    |> cast(attrs, [
      :media_type,
      :title,
      :original_title,
      :year,
      :tmdb_id,
      :tvdb_id,
      :imdb_id,
      :poster_path,
      :requester_notes,
      :requester_id
    ])
    |> validate_required([:media_type, :title, :requester_id])
    |> validate_inclusion(:media_type, @media_types)
    |> validate_inclusion(:status, @status_values)
    |> validate_at_least_one_external_id()
    |> foreign_key_constraint(:requester_id)
  end

  @doc """
  Changeset for approving a media request.
  """
  def approve_changeset(media_request, attrs) do
    media_request
    |> cast(attrs, [:admin_notes, :approved_by_id, :media_item_id])
    |> validate_required([:approved_by_id])
    |> put_change(:status, "approved")
    |> put_change(:approved_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> foreign_key_constraint(:approved_by_id)
    |> foreign_key_constraint(:media_item_id)
  end

  @doc """
  Changeset for rejecting a media request.
  """
  def reject_changeset(media_request, attrs) do
    media_request
    |> cast(attrs, [:rejection_reason, :admin_notes, :approved_by_id])
    |> validate_required([:rejection_reason, :approved_by_id])
    |> put_change(:status, "rejected")
    |> put_change(:rejected_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> foreign_key_constraint(:approved_by_id)
  end

  @doc """
  Returns the list of valid status values.
  """
  def valid_statuses, do: @status_values

  @doc """
  Returns the list of valid media types.
  """
  def valid_media_types, do: @media_types

  @doc """
  Returns the provider and id this request can be resolved with, or nil.

  TMDB wins when both ids are present: it is the id the request flow stores by
  default, and `MediaAddHelpers.fetch_detail_metadata/2` already resolves a
  TMDB show to TVDB when the instance is configured that way.
  """
  @spec external_ref(t()) :: {:tmdb, integer()} | {:tvdb, integer()} | nil
  def external_ref(%__MODULE__{tmdb_id: tmdb_id}) when is_integer(tmdb_id), do: {:tmdb, tmdb_id}
  def external_ref(%__MODULE__{tvdb_id: tvdb_id}) when is_integer(tvdb_id), do: {:tvdb, tvdb_id}
  def external_ref(%__MODULE__{}), do: nil

  @doc """
  Whether this request can be resolved against a metadata provider.

  False for an IMDb-only request, which `validate_at_least_one_external_id/1`
  permits. Gates the poster backfill, the clickable title and the detail popup
  together so those three never disagree about which rows are usable.
  """
  @spec detailable?(t()) :: boolean()
  def detailable?(%__MODULE__{} = request), do: external_ref(request) != nil

  @doc """
  The stored `media_type` string as the atom the metadata and card APIs take.
  """
  @spec media_type_atom(t()) :: :movie | :tv_show
  def media_type_atom(%__MODULE__{media_type: "tv_show"}), do: :tv_show
  def media_type_atom(%__MODULE__{}), do: :movie

  # Ensure at least one external ID (TMDB, TVDB, or IMDB) is provided
  defp validate_at_least_one_external_id(changeset) do
    tmdb_id = get_field(changeset, :tmdb_id)
    tvdb_id = get_field(changeset, :tvdb_id)
    imdb_id = get_field(changeset, :imdb_id)

    if is_nil(tmdb_id) && is_nil(tvdb_id) && is_nil(imdb_id) do
      add_error(changeset, :tmdb_id, "either TMDB ID, TVDB ID, or IMDB ID must be provided")
    else
      changeset
    end
  end
end
