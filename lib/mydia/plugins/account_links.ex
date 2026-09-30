defmodule Mydia.Plugins.AccountLinks do
  @moduledoc """
  Account links: the host-owned record of which credentials a plugin instance
  may use.

  Three roles share one table:

    * `:owner` - the instance's account-level credential for the remote
      service (for Plex, the plex.tv account token). No Mydia user.
    * `:endpoint` - an optional separate credential for the instance's
      approved endpoints (for Plex, a shared server's access token). No user.
    * `:user` - one Mydia user's link to one remote account, created by the
      user's own device flow (`:user_flow`), an admin's mapping
      (`:admin_mapped`) or the plugin's seeding (`:seeded`).

  Tokens never cross into a guest except where the contract says so: a guest
  sees identity and status through `links-list`, and the host injects the token
  into `link-request` itself using the manifest's `auth_header` template.
  """

  import Ecto.Query

  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.Instances
  alias Mydia.Repo

  @spec list(binary()) :: [AccountLink.t()]
  def list(instance_id) do
    Repo.all(
      from l in AccountLink,
        where: l.instance_id == ^instance_id,
        order_by: [asc: l.role, asc: l.inserted_at]
    )
  end

  @spec get(term()) :: AccountLink.t() | nil
  def get(link_id) do
    if uuid?(link_id), do: Repo.get(AccountLink, link_id), else: nil
  end

  @doc "A link by id, only if it belongs to `instance_id` (host functions use this)."
  @spec get_in_instance(binary(), term()) :: AccountLink.t() | nil
  def get_in_instance(instance_id, link_id) do
    if uuid?(link_id) do
      Repo.one(from l in AccountLink, where: l.id == ^link_id and l.instance_id == ^instance_id)
    end
  end

  @spec credential(binary(), :owner | :endpoint) :: AccountLink.t() | nil
  def credential(instance_id, role) when role in [:owner, :endpoint] do
    Repo.one(from l in AccountLink, where: l.instance_id == ^instance_id and l.role == ^role)
  end

  @spec user_link(binary(), binary()) :: AccountLink.t() | nil
  def user_link(instance_id, user_id) do
    Repo.one(
      from l in AccountLink,
        where: l.instance_id == ^instance_id and l.role == :user and l.user_id == ^user_id
    )
  end

  @spec put_credential(binary(), :owner | :endpoint, String.t()) :: {:ok, AccountLink.t()}
  def put_credential(instance_id, role, token)
      when role in [:owner, :endpoint] and is_binary(token) do
    instance = Instances.get!(instance_id)

    link =
      (credential(instance_id, role) || %AccountLink{})
      |> AccountLink.changeset(%{
        instance_id: instance.id,
        plugin_slug: instance.plugin_slug,
        role: role,
        source: :setup,
        access_token: token,
        status: :active,
        last_error: nil
      })
      |> Repo.insert_or_update!()

    {:ok, link}
  end

  @doc """
  Creates or refreshes the link a user makes through the device flow (the
  Integrations page).
  """
  @spec upsert_user_flow_link(binary(), binary(), map()) ::
          {:ok, AccountLink.t()} | {:error, Ecto.Changeset.t()}
  def upsert_user_flow_link(instance_id, user_id, attrs) do
    instance = Instances.get!(instance_id)

    (user_link(instance_id, user_id) || %AccountLink{})
    |> AccountLink.changeset(
      Map.merge(attrs, %{
        instance_id: instance.id,
        plugin_slug: instance.plugin_slug,
        user_id: user_id,
        role: :user,
        source: Map.get(attrs, :source, :user_flow)
      })
    )
    |> Repo.insert_or_update()
  end

  @doc """
  Makes the instance's user links exactly `mappings`.

  A user keeps their link row (and minted token) while they stay mapped to the
  same remote account. Remapping a user to another remote account clears the
  token so the plugin mints a fresh one. Unmapped users' links are deleted, and
  their store prefixes are swept after the transaction commits. Never call a
  remote service from inside this function (SQLite write lock).
  """
  @spec replace_user_links(binary(), [map()], atom()) ::
          {:ok, [AccountLink.t()]} | {:error, term()}
  def replace_user_links(instance_id, mappings, source) when is_list(mappings) do
    with :ok <- unique_by(mappings, :remote_account_id, :duplicate_remote_account),
         :ok <- unique_by(mappings, :user_id, :duplicate_user) do
      instance = Instances.get!(instance_id)
      keep_user_ids = Enum.map(mappings, & &1.user_id)

      result =
        Repo.transaction(fn ->
          removed =
            Repo.all(
              from l in AccountLink,
                where:
                  l.instance_id == ^instance_id and l.role == :user and
                    l.user_id not in ^keep_user_ids
            )

          Enum.each(removed, &Repo.delete!/1)
          links = Enum.map(mappings, &upsert_mapped!(instance, &1, source))
          {links, removed}
        end)

      case result do
        {:ok, {links, removed}} ->
          Enum.each(removed, &sweep_store/1)
          {:ok, links}

        {:error, _} = err ->
          err
      end
    end
  end

  defp upsert_mapped!(instance, mapping, source) do
    existing = user_link(instance.id, mapping.user_id)
    same_account? = existing != nil and existing.external_user_id == mapping.remote_account_id

    attrs = %{
      instance_id: instance.id,
      plugin_slug: instance.plugin_slug,
      user_id: mapping.user_id,
      role: :user,
      source: source,
      external_user_id: mapping.remote_account_id,
      external_username: mapping.remote_username
    }

    attrs =
      if same_account?,
        do: attrs,
        else: Map.merge(attrs, %{access_token: nil, status: :active, last_error: nil})

    (existing || %AccountLink{})
    |> AccountLink.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  @spec set_token(term(), String.t()) :: :ok | {:error, :not_found}
  def set_token(link_id, token) when is_binary(token) do
    case get(link_id) do
      # :disabled is the host-side kill switch: a new token is stored but the
      # link is never reactivated by it. Only an explicit host set_status/3 can.
      %AccountLink{status: :disabled} ->
        update_link(link_id, %{access_token: token})

      _ ->
        update_link(link_id, %{access_token: token, status: :active, last_error: nil})
    end
  end

  @spec set_status(term(), :active | :error | :disabled, String.t() | nil) ::
          :ok | {:error, :not_found}
  def set_status(link_id, status, message) when status in [:active, :error, :disabled] do
    update_link(link_id, %{status: status, last_error: truncate(message)})
  end

  defp update_link(link_id, attrs) do
    case get(link_id) do
      nil ->
        {:error, :not_found}

      link ->
        link |> AccountLink.changeset(attrs) |> Repo.update!()
        :ok
    end
  end

  @doc """
  Flips the named users' *active* links on `instance_id` to `:error`. Ids that
  are not well-formed UUIDs are dropped first: a guest result can name
  anything, and on PostgreSQL a non-UUID raises against the binary_id column.
  Returns the number flipped.
  """
  @spec mark_errored(binary(), [term()]) :: non_neg_integer()
  def mark_errored(instance_id, user_ids) when is_list(user_ids) do
    valid_ids = Enum.filter(user_ids, &uuid?/1)

    {count, _} =
      Repo.update_all(
        from(l in AccountLink,
          where:
            l.instance_id == ^instance_id and l.role == :user and l.user_id in ^valid_ids and
              l.status == :active
        ),
        set: [status: :error, updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

    count
  end

  @spec list_for_user(binary()) :: [AccountLink.t()]
  def list_for_user(user_id) do
    Repo.all(
      from l in AccountLink,
        where: l.user_id == ^user_id,
        order_by: [asc: l.plugin_slug, asc: l.inserted_at],
        preload: [:instance]
    )
  end

  @spec delete(AccountLink.t()) :: :ok
  def delete(%AccountLink{} = link) do
    Repo.delete_all(from l in AccountLink, where: l.id == ^link.id)
    sweep_store(link)
  end

  @doc """
  Per-link plugin state goes with the link: sweeps `link/<id>/` (1.4) and the
  legacy `conn/<id>/` (1.1 to 1.3 guests) from the link's instance store.
  """
  @spec sweep_store(AccountLink.t()) :: :ok
  def sweep_store(%AccountLink{instance_id: instance_id, id: id}) do
    Mydia.Plugins.Kv.delete_link_prefix(instance_id, id)
    :ok
  end

  defp unique_by(mappings, key, error) do
    values = Enum.map(mappings, &Map.fetch!(&1, key))
    if length(values) == length(Enum.uniq(values)), do: :ok, else: {:error, error}
  end

  defp truncate(nil), do: nil
  defp truncate(message) when is_binary(message), do: String.slice(message, 0, 500)

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
end
