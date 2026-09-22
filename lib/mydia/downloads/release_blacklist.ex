defmodule Mydia.Downloads.ReleaseBlacklist do
  @moduledoc """
  Ecto schema for a single blacklisted release.

  Rows are produced by `Mydia.Jobs.DownloadMonitor.handle_failure/1` whenever
  a download enters the `:error` state and consumed by
  `Mydia.Downloads.Blacklists.blacklisted?/2` from the search orchestrators
  (`TvShowSearch`, `MovieSearch`) before results are ranked.

  See `Mydia.Downloads.Blacklists` for the public API.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{
          id: binary() | nil,
          indexer: String.t(),
          guid: String.t(),
          title: String.t(),
          failure_reason: String.t(),
          expires_at: DateTime.t() | nil,
          info_hash: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "release_blacklist" do
    field :indexer, :string
    field :guid, :string
    field :title, :string
    field :failure_reason, :string
    field :expires_at, :utc_datetime_usec
    # The torrent's v1 infohash (40-char lowercase hex), when known. Lets a ban
    # match the same torrent listed by another indexer under another guid.
    field :info_hash, :string

    # Custom timestamps — no updated_at, only inserted_at.
    field :inserted_at, :utc_datetime_usec
  end

  @required ~w(indexer guid title failure_reason)a
  @optional ~w(expires_at inserted_at info_hash)a

  @doc """
  Builds a changeset for the schema.

  `indexer` is normalized to lowercase here so the unique constraint catches
  `"Prowlarr"` vs `"prowlarr"` mismatches.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> update_change(:indexer, &normalize_indexer/1)
    |> update_change(:info_hash, &normalize_info_hash/1)
    |> unique_constraint([:indexer, :guid],
      name: :release_blacklist_indexer_guid_unique
    )
  end

  @doc """
  Normalizes an indexer name for storage/lookup. Lowercase, trimmed.
  """
  @spec normalize_indexer(String.t() | nil) :: String.t() | nil
  def normalize_indexer(nil), do: nil

  def normalize_indexer(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end

  @doc """
  Normalizes a v1 infohash for storage/lookup. Lowercase, trimmed.
  """
  @spec normalize_info_hash(String.t() | nil) :: String.t() | nil
  def normalize_info_hash(nil), do: nil

  def normalize_info_hash(hash) when is_binary(hash) do
    hash |> String.trim() |> String.downcase()
  end
end
