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

  @statuses ~w(connected error disabled)
  @scopes ~w(user instance)
  @auth_kinds ~w(header query bearer)

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
    field :scope, :string, default: "user"
    field :label, :string, default: ""
    field :base_urls, Mydia.Settings.JsonListType, default: []
    field :resolved_base_url, :string
    field :auth_kind, :string, default: "bearer"
    field :auth_key, :string
    field :from_config?, :boolean, virtual: true, default: false

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
      :meta,
      :scope,
      :label,
      :base_urls,
      :resolved_base_url,
      :auth_kind,
      :auth_key
    ])
    |> validate_required([:plugin_config_id, :plugin_slug, :access_token])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_scope()
    |> unique_constraint([:plugin_slug, :user_id, :label],
      name: :plugin_user_connections_user_label_index
    )
    |> unique_constraint([:plugin_slug, :label],
      name: :plugin_user_connections_instance_label_index
    )
    |> foreign_key_constraint(:plugin_config_id)
    |> foreign_key_constraint(:user_id)
  end

  # `user_id` is required for a user-scoped connection and forbidden for an
  # instance-scoped one. Enforcing both directions is what keeps the two partial
  # unique indexes meaningful: a stray user_id on an instance row would move it
  # into the other index and let a duplicate label through.
  defp validate_scope(changeset) do
    case get_field(changeset, :scope) do
      "instance" ->
        if get_field(changeset, :user_id) do
          add_error(changeset, :user_id, "must be nil for an instance-scoped connection")
        else
          changeset
        end

      _ ->
        validate_required(changeset, [:user_id])
    end
  end

  @doc """
  Creates or updates a connection, keyed by `{slug, user_id, label}`.

  An instance-scoped connection passes no `:user_id`. This is the write path for
  both the admin form and the guest's `connection-upsert`.
  """
  @spec upsert(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def upsert(slug, attrs) when is_binary(slug) and is_map(attrs) do
    case Settings.get_plugin_config_by_slug(slug) do
      nil ->
        {:error, :not_installed}

      %{id: config_id} ->
        scope = Map.get(attrs, :scope, "user")
        label = Map.get(attrs, :label, "")
        user_id = Map.get(attrs, :user_id)

        base =
          attrs
          |> Map.merge(%{
            plugin_slug: slug,
            plugin_config_id: config_id,
            scope: scope,
            label: label
          })

        (get_by_label(slug, user_id, label) || %Connections{})
        |> changeset(base)
        |> Repo.insert_or_update()
    end
  end

  @doc "Fetches the connection keyed by `{slug, user_id, label}`, or nil."
  @spec get_by_label(String.t(), binary() | nil, String.t()) :: t() | nil
  def get_by_label(slug, nil, label) when is_binary(slug) do
    Repo.one(
      from c in Connections,
        where: c.plugin_slug == ^slug and is_nil(c.user_id) and c.label == ^label
    )
  end

  def get_by_label(slug, user_id, label) when is_binary(slug) do
    Repo.one(
      from c in Connections,
        where: c.plugin_slug == ^slug and c.user_id == ^user_id and c.label == ^label
    )
  end

  @doc "Lists a plugin's instance-scoped connections, oldest first."
  @spec list_instance_for_plugin(String.t()) :: [t()]
  def list_instance_for_plugin(slug) when is_binary(slug) do
    Repo.all(
      from c in Connections,
        where: c.plugin_slug == ^slug and c.scope == "instance",
        order_by: c.inserted_at
    )
  end

  @doc """
  Caches the endpoint candidate that last worked, or clears it with `nil` so the
  next request re-probes.
  """
  @spec set_resolved_base_url(t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def set_resolved_base_url(%Connections{} = conn, url) do
    conn
    |> Ecto.Changeset.change(resolved_base_url: url)
    |> Repo.update()
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
        where: c.plugin_slug == ^slug and c.status == "connected" and not is_nil(c.user_id),
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
  Removes every connection a deleted user holds, sweeping each one's KV prefix
  first so per-user plugin state does not outlive the user. The `user_id` FK
  would cascade the rows on its own, but the KV keys (not user-scoped) need the
  application sweep.
  """
  @spec delete_for_user(binary()) :: :ok
  def delete_for_user(user_id) do
    for conn <- list_for_user(user_id) do
      Mydia.Plugins.Kv.delete_connection_prefix(conn.plugin_slug, conn.id)
    end

    Repo.delete_all(from c in Connections, where: c.user_id == ^user_id)
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
