defmodule Mydia.Plugins.Connections do
  @moduledoc """
  Per-user plugin connections: the pre-1.4 API over account links.

  A connection is a `:user` account link on the plugin's **default instance**,
  created by the user's own device flow. Simkl, the Integrations page and
  account deletion use this module; 1.4 plugins and the admin mapping flow use
  `Mydia.Plugins.AccountLinks` directly.

  The plugin never receives a token. It reads identity and status through
  `connections-list` / `links-list` and references a link by id for
  host-attached auth; the host attaches the token itself.

  Cross-user surfaces are consent-scoped: only a user holding an *active* user
  link to the plugin (on any of its instances) is visible to the plugin's reads
  and writable by its write-backs. `connected_user_ids/1` and `active?/2` are
  that boundary.
  """

  import Ecto.Query

  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instances
  alias Mydia.Repo
  alias Mydia.Settings

  @type t :: AccountLink.t()

  @doc """
  Creates or refreshes the connection for `{slug, user_id}` on the plugin's
  default instance. Fails with `:not_installed` when the plugin is unknown.
  """
  @spec connect(String.t(), binary(), map()) :: {:ok, t()} | {:error, term()}
  def connect(slug, user_id, attrs) when is_binary(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:error, :not_installed}

      _config ->
        case Instances.default_instance(slug) do
          nil ->
            {:error, :not_connectable}

          instance ->
            with {:ok, status} <- normalize_status(Map.get(attrs, :status, :active)) do
              attrs =
                attrs
                |> Map.take([:access_token, :external_user_id, :external_username, :meta])
                |> Map.put(:status, status)

              AccountLinks.upsert_user_flow_link(instance.id, user_id, attrs)
            end
        end
    end
  end

  @doc "The connection for `{slug, user_id}` on the default instance, or nil."
  @spec get(String.t(), binary()) :: t() | nil
  def get(slug, user_id) when is_binary(slug) do
    case Instances.default_instance(slug) do
      nil -> nil
      instance -> AccountLinks.user_link(instance.id, user_id)
    end
  end

  @doc "A user link by id scoped to a plugin (any of its instances)."
  @spec get_by_id(String.t(), binary()) :: t() | nil
  def get_by_id(slug, id) when is_binary(slug) and is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        Repo.one(
          from l in AccountLink,
            where: l.plugin_slug == ^slug and l.id == ^id and l.role == :user
        )

      :error ->
        nil
    end
  end

  @doc "Every user link a plugin holds, across its instances."
  @spec list_for_plugin(String.t()) :: [t()]
  def list_for_plugin(slug) when is_binary(slug) do
    Repo.all(
      from l in AccountLink,
        where: l.plugin_slug == ^slug and l.role == :user,
        order_by: l.inserted_at
    )
  end

  @doc "A user's links across all plugins (ProfileLive, account deletion)."
  @spec list_for_user(binary()) :: [t()]
  def list_for_user(user_id), do: AccountLinks.list_for_user(user_id)

  @doc "User ids with an active link to the plugin: the consent boundary."
  @spec connected_user_ids(String.t()) :: [binary()]
  def connected_user_ids(slug) when is_binary(slug) do
    Repo.all(
      from l in AccountLink,
        where: l.plugin_slug == ^slug and l.role == :user and l.status == :active,
        select: l.user_id,
        distinct: true
    )
  end

  @doc "True when `user_id` has an active link to the plugin."
  @spec active?(String.t(), binary()) :: boolean()
  def active?(slug, user_id) when is_binary(slug) do
    Repo.exists?(
      from l in AccountLink,
        where:
          l.plugin_slug == ^slug and l.role == :user and l.user_id == ^user_id and
            l.status == :active
    )
  end

  @doc "Deletes the default-instance connection for `{slug, user_id}`."
  @spec delete(String.t(), binary()) :: :ok
  def delete(slug, user_id) when is_binary(slug) do
    case get(slug, user_id) do
      nil ->
        :ok

      link ->
        Repo.delete_all(from l in AccountLink, where: l.id == ^link.id)
        :ok
    end
  end

  @doc "Disconnects `{slug, user_id}`: deletes the link and sweeps its store prefix."
  @spec disconnect(String.t(), binary()) :: :ok
  def disconnect(slug, user_id) when is_binary(slug) do
    case get(slug, user_id) do
      nil -> :ok
      link -> AccountLinks.delete(link)
    end
  end

  @doc """
  Sweeps the store prefix of each link. Callers collect the links with
  `list_for_user/1` *before* deleting the user (the FK cascade removes the rows)
  and call this only once the delete succeeded.
  """
  @spec sweep_kv([t()]) :: :ok
  def sweep_kv(links) when is_list(links) do
    Enum.each(links, &AccountLinks.sweep_store/1)
  end

  @doc """
  Marks the named users' active links to the plugin (every instance) as
  `:error`. Returns the number flipped.
  """
  @spec mark_errored(String.t(), [binary()]) :: non_neg_integer()
  def mark_errored(slug, user_ids) when is_binary(slug) and is_list(user_ids) do
    slug
    |> Instances.list()
    |> Enum.map(&AccountLinks.mark_errored(&1.id, user_ids))
    |> Enum.sum()
  end

  @doc "Counts the user links a plugin holds (uninstall confirmation copy)."
  @spec count_for_plugin(String.t()) :: non_neg_integer()
  def count_for_plugin(slug) when is_binary(slug) do
    Repo.aggregate(
      from(l in AccountLink, where: l.plugin_slug == ^slug and l.role == :user),
      :count,
      :id
    )
  end

  defp normalize_status(status) when status in [:active, "active", :connected, "connected"],
    do: {:ok, :active}

  defp normalize_status(status) when status in [:error, "error"], do: {:ok, :error}
  defp normalize_status(status) when status in [:disabled, "disabled"], do: {:ok, :disabled}
  defp normalize_status(other), do: {:error, {:invalid_status, other}}
end
