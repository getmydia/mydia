defmodule Mydia.Config.Schema.AuthChangeset do
  @moduledoc """
  Changeset for the `auth` section of `Mydia.Config.Schema`.

  With OIDC enabled, a client ID, a client secret and an issuer (or the legacy
  discovery document URI) are required. `oidc_default_role` is the role an
  account created by its first SSO sign-in gets when the identity provider's
  roles and groups claims grant none, and admin is not one of the choices: it
  would make every account at the identity provider a Mydia admin.
  """

  import Ecto.Changeset

  @oidc_default_roles ~w(guest readonly user)

  @doc "Roles `auth.oidc_default_role` accepts. Admin is deliberately absent."
  @spec oidc_default_roles() :: [String.t()]
  def oidc_default_roles, do: @oidc_default_roles

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :local_enabled,
      :oidc_enabled,
      :oidc_issuer,
      :oidc_discovery_document_uri,
      :oidc_client_id,
      :oidc_client_secret,
      :oidc_redirect_uri,
      :oidc_scopes,
      :oidc_link_by_email,
      :oidc_default_role,
      :jwt_ttl_days,
      :jwt_allowed_drift
    ])
    |> validate_required([:local_enabled, :oidc_enabled, :oidc_default_role])
    |> validate_inclusion(:oidc_default_role, @oidc_default_roles)
    |> validate_oidc_config()
    |> validate_number(:jwt_ttl_days, greater_than: 0)
    |> validate_number(:jwt_allowed_drift, greater_than_or_equal_to: 0)
  end

  defp validate_oidc_config(changeset) do
    if get_field(changeset, :oidc_enabled) do
      changeset
      |> validate_required([:oidc_client_id, :oidc_client_secret])
      |> validate_oidc_issuer()
    else
      changeset
    end
  end

  defp validate_oidc_issuer(changeset) do
    issuer = get_field(changeset, :oidc_issuer)
    discovery = get_field(changeset, :oidc_discovery_document_uri)

    if is_nil(issuer) and is_nil(discovery) do
      add_error(
        changeset,
        :oidc_issuer,
        "either oidc_issuer or oidc_discovery_document_uri must be provided when OIDC is enabled"
      )
    else
      changeset
    end
  end
end
