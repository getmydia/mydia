defmodule Mydia.Plugins.Connections do
  @moduledoc """
  Per-user plugin connections (U7): the OAuth token, external account identity,
  and a status lifecycle the host stores and manages on a plugin's behalf.

  The plugin never receives a token. It reads identity + status through the
  `connections-list` host function and references a connection by id for
  host-attached auth (`connection-request`); the host attaches the bearer token
  itself (R22). The token column is `redact: true`, so struct inspection never
  surfaces it in logs or crash reports.

  Cross-user surfaces are consent-scoped (R21): only a user who has clicked
  Connect (an *active* connection, `status: "connected"`) is visible to the
  plugin's reads and writable by its write-backs. `connected_user_ids/1` and
  `active?/2` are that boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Mydia.Plugins.Connections
  alias Mydia.Repo
  alias Mydia.Settings

  @statuses ~w(connected error)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "plugin_user_connections" do
    field :plugin_config_id, :binary_id
    field :plugin_slug, :string
    field :status, :string, default: "connected"
    field :access_token, :string, redact: true
    field :external_user_id, :string
    field :external_username, :string
    field :meta, Mydia.Settings.JsonMapType, default: %{}

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :plugin_config_id,
      :plugin_slug,
      :user_id,
      :status,
      :access_token,
      :external_user_id,
      :external_username,
      :meta
    ])
    |> validate_required([:plugin_config_id, :plugin_slug, :user_id, :access_token])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:plugin_slug, :user_id])
    |> foreign_key_constraint(:plugin_config_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Creates or refreshes the connection for `{slug, user_id}` (e.g. on connect or
  reconnect). Resolves the owning config from the slug; fails if the plugin is
  not installed.
  """
  @spec connect(String.t(), binary(), map()) :: {:ok, t()} | {:error, term()}
  def connect(slug, user_id, attrs) when is_binary(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:error, :not_installed}

      %{id: config_id} ->
        base =
          Map.merge(attrs, %{
            plugin_slug: slug,
            plugin_config_id: config_id,
            user_id: user_id,
            status: Map.get(attrs, :status, "connected")
          })

        (get(slug, user_id) || %Connections{})
        |> changeset(base)
        |> Repo.insert_or_update()
    end
  end

  @doc "Fetches the connection for `{slug, user_id}`, or nil."
  @spec get(String.t(), binary()) :: t() | nil
  def get(slug, user_id) when is_binary(slug) do
    Repo.one(from c in Connections, where: c.plugin_slug == ^slug and c.user_id == ^user_id)
  end

  @doc "Fetches a connection by its id scoped to a plugin (host-attached auth)."
  @spec get_by_id(String.t(), binary()) :: t() | nil
  def get_by_id(slug, id) when is_binary(slug) and is_binary(id) do
    Repo.one(from c in Connections, where: c.plugin_slug == ^slug and c.id == ^id)
  end

  @doc "Lists every connection a plugin holds (for connections-list)."
  @spec list_for_plugin(String.t()) :: [t()]
  def list_for_plugin(slug) when is_binary(slug) do
    Repo.all(from c in Connections, where: c.plugin_slug == ^slug, order_by: c.inserted_at)
  end

  @doc "Lists a user's connections across all plugins (for ProfileLive)."
  @spec list_for_user(binary()) :: [t()]
  def list_for_user(user_id) do
    Repo.all(from c in Connections, where: c.user_id == ^user_id, order_by: c.plugin_slug)
  end

  @doc """
  The user ids with an *active* (status `connected`) connection to the plugin —
  the consent boundary for cross-user reads/writes (R21).
  """
  @spec connected_user_ids(String.t()) :: [binary()]
  def connected_user_ids(slug) when is_binary(slug) do
    Repo.all(
      from c in Connections,
        where: c.plugin_slug == ^slug and c.status == "connected",
        select: c.user_id
    )
  end

  @doc "True when `user_id` has an active connection to the plugin (R21)."
  @spec active?(String.t(), binary()) :: boolean()
  def active?(slug, user_id) when is_binary(slug) do
    Repo.exists?(
      from c in Connections,
        where: c.plugin_slug == ^slug and c.user_id == ^user_id and c.status == "connected"
    )
  end

  @doc "Deletes the connection for `{slug, user_id}` (disconnect)."
  @spec delete(String.t(), binary()) :: :ok
  def delete(slug, user_id) when is_binary(slug) do
    Repo.delete_all(
      from c in Connections, where: c.plugin_slug == ^slug and c.user_id == ^user_id
    )

    :ok
  end

  @doc """
  Disconnects `{slug, user_id}`: sweeps the connection's `conn/<id>/` KV prefix
  (so the user's per-connection state goes with them, U3) and deletes the row.
  """
  @spec disconnect(String.t(), binary()) :: :ok
  def disconnect(slug, user_id) when is_binary(slug) do
    case get(slug, user_id) do
      nil ->
        :ok

      conn ->
        Mydia.Plugins.Kv.delete_connection_prefix(slug, conn.id)
        delete(slug, user_id)
    end
  end

  @doc """
  Sweeps the `conn/<id>/` KV prefix of each of `connections`, so per-user plugin
  state does not outlive the user who owned it.

  Deleting the user cascades the connection rows themselves through the `user_id`
  FK, but the KV keys are not user-scoped and need this application sweep. Callers
  therefore collect the connections with `list_for_user/1` *before* the delete
  (the rows are gone afterwards) and call this only once the delete has actually
  succeeded -- sweeping first would destroy plugin state that nothing restores if
  the delete is then rejected.
  """
  @spec sweep_kv([Connections.t()]) :: :ok
  def sweep_kv(connections) when is_list(connections) do
    for conn <- connections do
      Mydia.Plugins.Kv.delete_connection_prefix(conn.plugin_slug, conn.id)
    end

    :ok
  end

  @doc """
  Marks the named users' connections to the plugin as `error` — but only those
  that actually hold an active connection (a guest result can't mass-error state
  or inject ids). Returns the number flipped.
  """
  @spec mark_errored(String.t(), [binary()]) :: non_neg_integer()
  def mark_errored(slug, user_ids) when is_binary(slug) and is_list(user_ids) do
    # Drop ids that aren't well-formed UUIDs before the `in` query. A guest result
    # can name arbitrary strings; on Postgres a non-UUID value raises a CastError
    # against the binary_id column (SQLite stores ids as text and would silently
    # not match). A malformed id could never match a real connection anyway, so
    # filtering leaves the flipped count identical on both engines.
    valid_ids = Enum.filter(user_ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))

    {count, _} =
      Repo.update_all(
        from(c in Connections,
          where: c.plugin_slug == ^slug and c.user_id in ^valid_ids and c.status == "connected"
        ),
        set: [status: "error", updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

    count
  end

  @doc "Counts the connections a plugin holds (uninstall confirmation copy)."
  @spec count_for_plugin(String.t()) :: non_neg_integer()
  def count_for_plugin(slug) when is_binary(slug) do
    Repo.aggregate(from(c in Connections, where: c.plugin_slug == ^slug), :count, :id)
  end
end
