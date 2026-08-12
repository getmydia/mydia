defmodule Mydia.Settings.MediaServerUserLink do
  @moduledoc """
  Binds one Mydia user to one account on a media server.

  Without this, the sync scheduler fanned out over every Mydia user against a
  single admin token, so all users read and wrote the same remote watch state.
  A user with no link is skipped rather than defaulted, because defaulting is
  what silently merged separate people's history.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          media_server_config_id: binary(),
          user_id: binary(),
          remote_user_id: String.t() | nil,
          remote_username: String.t() | nil,
          access_token: String.t() | nil,
          enabled: boolean(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "media_server_user_links" do
    field :remote_user_id, :string
    field :remote_username, :string
    field :access_token, :string, redact: true
    field :enabled, :boolean, default: true

    belongs_to :media_server_config, Mydia.Settings.MediaServerConfig
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  The name to show an operator for the remote account this link names.

  Discovery reports the mappings it left alone, and a mapping is only meaningful
  to the operator under the account it actually points at. Falls back to the
  account id, then to a placeholder, because a link is allowed to carry neither
  (Plex's owner fallback writes one that carries only a token).
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{remote_username: name}) when is_binary(name) and name != "",
    do: name

  def display_name(%__MODULE__{remote_user_id: id}) when is_binary(id) and id != "", do: id

  def display_name(%__MODULE__{}), do: "an existing mapping"

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :media_server_config_id,
      :user_id,
      :remote_user_id,
      :remote_username,
      :access_token,
      :enabled
    ])
    |> validate_required([:media_server_config_id, :user_id])
    |> unique_constraint([:media_server_config_id, :user_id])
    # The mirror of the above: one account per Mydia user, and one Mydia user per
    # account. `Settings.upsert_media_server_user_link/1` refuses the second case
    # before the insert, so this only catches a race.
    |> unique_constraint([:media_server_config_id, :remote_user_id],
      name: :media_server_user_links_config_remote_user_index
    )
    |> foreign_key_constraint(:media_server_config_id)
    |> foreign_key_constraint(:user_id)
  end
end
