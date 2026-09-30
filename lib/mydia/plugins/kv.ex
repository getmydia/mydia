defmodule Mydia.Plugins.Kv do
  @moduledoc """
  Per-plugin key/value state (U3), gated by the `state:kv` capability.

  A small, opaque-string store a plugin uses to persist watermarks, cursors, and
  dedupe sets across invocations. Values are opaque to the host — never decoded —
  and bounded by per-plugin quotas (`@max_keys` keys, `@max_value_bytes` per
  value) so a single plugin cannot exhaust the shared table.

  Each row carries the owning `plugin_config_id` (`null: false`, cascade-deleted)
  plus the denormalized `plugin_slug` the API keys on, so an uninstall racing an
  in-flight write fails on the FK rather than resurrecting state (KTD: the
  `plugin_logs` pattern).

  ## Reserved connection prefix

  Keys under `conn/<connection-id>/...` are a documented, host-sweepable
  exception to key opacity: `delete_connection_prefix/2` removes a single
  connection's per-user state when that connection is removed (U7), so a deleted
  user's state does not outlive them.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Kv
  alias Mydia.Repo
  alias Mydia.Settings

  @max_keys 256
  @max_value_bytes 64 * 1024
  @max_key_bytes 512

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "plugin_kv" do
    field :plugin_config_id, :binary_id
    field :instance_id, :binary_id
    field :plugin_slug, :string
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Maximum number of keys a single plugin may hold."
  @spec max_keys() :: pos_integer()
  def max_keys, do: @max_keys

  @doc "Maximum byte size of a single value."
  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @doc """
  Fetches the value for `key`, or `nil` when absent.
  """
  @spec get(String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def get(slug, key) when is_binary(slug) and is_binary(key) do
    case Repo.one(from k in Kv, where: k.plugin_slug == ^slug and k.key == ^key, select: k.value) do
      nil -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  @doc """
  Upserts `value` under `key` (engine-native, last-write-wins).

  Enforces the value-size quota and, for a new key, the key-count quota. Fails
  with `:not_found` when the plugin is no longer installed (the uninstall race).
  """
  @spec set(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def set(slug, key, value) when is_binary(slug) and is_binary(key) and is_binary(value) do
    with :ok <- check_value_size(value),
         {:ok, config_id} <- resolve_config_id(slug),
         :ok <- check_key_quota(slug, key) do
      instance_id = Mydia.Plugins.Instances.default_instance(slug).id
      upsert(slug, config_id, instance_id, key, value)
    end
  end

  @doc """
  Deletes `key` for the plugin. A no-op (still `:ok`) when the key is absent.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(slug, key) when is_binary(slug) and is_binary(key) do
    Repo.delete_all(from k in Kv, where: k.plugin_slug == ^slug and k.key == ^key)
    :ok
  end

  @doc """
  Sweeps every `conn/<connection_id>/...` key for the plugin, returning the
  number of rows removed. Used when a connection is removed (U7).
  """
  @spec delete_connection_prefix(String.t(), String.t()) :: non_neg_integer()
  def delete_connection_prefix(slug, connection_id)
      when is_binary(slug) and is_binary(connection_id) do
    prefix = "conn/" <> connection_id <> "/%"

    {count, _} =
      Repo.delete_all(from k in Kv, where: k.plugin_slug == ^slug and like(k.key, ^prefix))

    count
  end

  @doc "Returns the number of keys the plugin currently holds."
  @spec key_count(String.t()) :: non_neg_integer()
  def key_count(slug) when is_binary(slug) do
    Repo.aggregate(from(k in Kv, where: k.plugin_slug == ^slug), :count, :id)
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp check_value_size(value) do
    if byte_size(value) > @max_value_bytes do
      {:error, Error.new(:invalid_request, "value exceeds #{@max_value_bytes}-byte limit")}
    else
      :ok
    end
  end

  defp resolve_config_id(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{id: id} -> {:ok, id}
      nil -> {:error, Error.new(:not_found, "plugin #{slug} is not installed")}
    end
  end

  # The key-count quota only bites a *new* key; overwriting an existing one is
  # always allowed. Per-plugin invocation single-flight (U4) serializes writes,
  # so this read-then-write is race-free in practice.
  defp check_key_quota(slug, key) do
    exists? = Repo.exists?(from k in Kv, where: k.plugin_slug == ^slug and k.key == ^key)

    cond do
      exists? ->
        :ok

      key_count(slug) >= @max_keys ->
        {:error, Error.new(:invalid_request, "key quota (#{@max_keys}) exceeded")}

      byte_size(key) > @max_key_bytes ->
        {:error, Error.new(:invalid_request, "key exceeds #{@max_key_bytes}-byte limit")}

      true ->
        :ok
    end
  end

  defp upsert(slug, config_id, instance_id, key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    entry = %{
      id: Ecto.UUID.generate(),
      plugin_config_id: config_id,
      instance_id: instance_id,
      plugin_slug: slug,
      key: key,
      value: value,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Kv, [entry],
           on_conflict: [set: [value: value, updated_at: now]],
           conflict_target: [:instance_id, :key]
         ) do
      {n, _} when n >= 1 -> {:ok, value}
      _ -> {:error, Error.new(:internal, "kv write failed")}
    end
  rescue
    Ecto.ConstraintError ->
      # FK violation: the plugin was uninstalled between resolve and insert.
      {:error, Error.new(:not_found, "plugin #{slug} is not installed")}
  end
end
