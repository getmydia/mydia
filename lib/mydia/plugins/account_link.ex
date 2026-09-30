defmodule Mydia.Plugins.AccountLink do
  @moduledoc """
  A credential or user link held by the host for one plugin instance.

  `owner` and `endpoint` links have no Mydia user: they hold the instance's
  account-level credential and the optional credential for its approved
  endpoints. `user` links map a Mydia user to a remote account. The token is
  never sent to a guest (`redact: true` keeps it out of logs too).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_account_links" do
    field :plugin_slug, :string
    field :role, Ecto.Enum, values: [:owner, :endpoint, :user], default: :user

    field :source, Ecto.Enum,
      values: [:user_flow, :admin_mapped, :seeded, :setup],
      default: :user_flow

    field :status, Ecto.Enum, values: [:active, :error, :disabled], default: :active
    field :access_token, :string, redact: true
    field :external_user_id, :string
    field :external_username, :string
    field :last_error, :string
    field :meta, Mydia.Settings.JsonMapType, default: %{}

    belongs_to :instance, Mydia.Plugins.Instance
    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :instance_id,
      :plugin_slug,
      :user_id,
      :role,
      :source,
      :status,
      :access_token,
      :external_user_id,
      :external_username,
      :last_error,
      :meta
    ])
    |> validate_required([:instance_id, :plugin_slug, :role, :source, :status])
    |> validate_user_for_role()
    |> unique_constraint([:instance_id, :user_id],
      name: :plugin_account_links_instance_user_index
    )
    |> unique_constraint([:instance_id, :external_user_id],
      name: :plugin_account_links_instance_external_index
    )
    |> unique_constraint([:instance_id, :role],
      name: :plugin_account_links_instance_credential_index
    )
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:user_id)
  end

  # Credentials belong to the instance, not to a person.
  defp validate_user_for_role(changeset) do
    case {get_field(changeset, :role), get_field(changeset, :user_id)} do
      {role, user_id} when role in [:owner, :endpoint] and not is_nil(user_id) ->
        add_error(changeset, :user_id, "must be empty for #{role} links")

      _ ->
        changeset
    end
  end
end
