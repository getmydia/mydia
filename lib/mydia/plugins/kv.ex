defmodule Mydia.Plugins.Kv do
  @moduledoc """
  Per-instance plugin store (contract 1.4), gated by the `state:kv` capability.

  An opaque-string store a plugin uses for its working state: cursors,
  checkpoints, mapping caches. Values are never decoded by the host. Keys are
  scoped to a plugin instance, so two instances of a multi-instance plugin hold
  independent state under the same keys.

  ## Limits

    * `max_value_bytes/0` (64 KiB) per value and 512 bytes per key, fixed.
    * `max_keys/0` and `max_bytes/0` per instance, from the operator config
      (`plugins.store_max_keys`, `plugins.store_max_bytes`). `size_bytes` caches
      each row's `byte_size(key) + byte_size(value)` so the byte quota is a SUM.
    * `max_batch/0` entries per `set_many/2`.

  Quota failures are `:capability_denied` ("store quota exceeded ..."), so the
  guest sees `denied`, and a batch is all-or-nothing.

  ## Reserved link prefixes

  Keys under `link/<link-id>/` (and the 1.1 to 1.3 spelling `conn/<link-id>/`)
  are a documented, host-sweepable exception to key opacity:
  `delete_link_prefix/2` removes them when that account link is deleted, so a
  removed user's state does not outlive them.

  ## Ordering

  `list/3` pages in the database's key order. Guests must not rely on anything
  beyond "every key under the prefix, each exactly once".
  """

  use Ecto.Schema

  import Ecto.Query

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Kv
  alias Mydia.Repo
  alias Mydia.Settings

  @max_value_bytes 64 * 1024
  @max_key_bytes 512
  @max_batch 500
  @list_page 200

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @doc false
  schema "plugin_kv" do
    field :plugin_config_id, :binary_id
    field :plugin_slug, :string
    field :instance_id, :binary_id
    field :key, :string
    field :value, :string
    field :size_bytes, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  @spec max_keys() :: pos_integer()
  def max_keys, do: store_config().store_max_keys

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: store_config().store_max_bytes

  @spec max_value_bytes() :: pos_integer()
  def max_value_bytes, do: @max_value_bytes

  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @spec list_page_size() :: pos_integer()
  def list_page_size, do: @list_page

  @doc "Fetches the value for `key`, or `nil` when absent."
  @spec get(binary(), String.t()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def get(instance_id, key) when is_binary(instance_id) and is_binary(key) do
    {:ok,
     Repo.one(
       from k in Kv, where: k.instance_id == ^instance_id and k.key == ^key, select: k.value
     )}
  end

  @doc "Upserts one key. See `set_many/2` for the rules."
  @spec set(binary(), String.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def set(instance_id, key, value) when is_binary(key) and is_binary(value) do
    with :ok <- set_many(instance_id, [{key, value}]), do: {:ok, value}
  end

  @doc """
  Upserts every `{key, value}` in one statement. All-or-nothing: a bad entry or
  a quota breach writes nothing. A key repeated in the batch keeps its last value.
  """
  @spec set_many(binary(), [{String.t(), String.t()}]) :: :ok | {:error, Error.t()}
  def set_many(instance_id, []) when is_binary(instance_id), do: :ok

  def set_many(instance_id, entries) when is_binary(instance_id) and is_list(entries) do
    entries = dedupe_last_wins(entries)

    with :ok <- validate_batch(entries),
         {:ok, instance} <- fetch_instance(instance_id),
         {:ok, config_id} <- resolve_config_id(instance.plugin_slug),
         :ok <- check_quota(instance_id, entries) do
      upsert_all(instance, config_id, entries)
    end
  end

  @doc "Deletes `key`. A no-op (still `:ok`) when absent."
  @spec delete(binary(), String.t()) :: :ok
  def delete(instance_id, key) when is_binary(instance_id) and is_binary(key) do
    Repo.delete_all(from k in Kv, where: k.instance_id == ^instance_id and k.key == ^key)
    :ok
  end

  @doc """
  Lists up to `list_page_size/0` entries whose key starts with `prefix`, after
  the opaque `cursor` (nil for the first page).
  """
  @spec list(binary(), String.t(), String.t() | nil) ::
          {:ok, %{entries: [{String.t(), String.t()}], next_cursor: String.t() | nil}}
          | {:error, Error.t()}
  def list(instance_id, prefix, cursor) when is_binary(instance_id) and is_binary(prefix) do
    with {:ok, after_key} <- decode_cursor(cursor) do
      rows =
        from(k in Kv,
          where: k.instance_id == ^instance_id,
          order_by: [asc: k.key],
          limit: ^(@list_page + 1),
          select: {k.key, k.value}
        )
        |> where_prefix(prefix)
        |> where_after(after_key)
        |> Repo.all()

      {page, more?} =
        if length(rows) > @list_page,
          do: {Enum.take(rows, @list_page), true},
          else: {rows, false}

      next = if more?, do: page |> List.last() |> elem(0) |> encode_cursor()
      {:ok, %{entries: page, next_cursor: next}}
    end
  end

  @doc "Deletes every key starting with `prefix`; returns the count removed."
  @spec delete_prefix(binary(), String.t()) :: non_neg_integer()
  def delete_prefix(instance_id, prefix)
      when is_binary(instance_id) and is_binary(prefix) and prefix != "" do
    {count, _} =
      from(k in Kv, where: k.instance_id == ^instance_id)
      |> where_prefix(prefix)
      |> Repo.delete_all()

    count
  end

  @doc "Sweeps an account link's reserved keys (`link/<id>/` and legacy `conn/<id>/`)."
  @spec delete_link_prefix(binary(), binary()) :: non_neg_integer()
  def delete_link_prefix(instance_id, link_id) when is_binary(link_id) do
    delete_prefix(instance_id, "link/#{link_id}/") +
      delete_prefix(instance_id, "conn/#{link_id}/")
  end

  @doc "Current key count and byte total for the instance."
  @spec usage(binary()) :: %{keys: non_neg_integer(), bytes: non_neg_integer()}
  def usage(instance_id) when is_binary(instance_id) do
    {keys, bytes} =
      Repo.one(
        from k in Kv,
          where: k.instance_id == ^instance_id,
          select: {count(k.id), coalesce(sum(k.size_bytes), 0)}
      )

    %{keys: keys, bytes: to_int(bytes)}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp dedupe_last_wins(entries) do
    entries |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
  end

  defp validate_batch(entries) do
    cond do
      length(entries) > @max_batch ->
        {:error, Error.new(:invalid_request, "batch exceeds #{@max_batch} entries")}

      bad = Enum.find(entries, &(not valid_entry?(&1))) ->
        {:error, Error.new(:invalid_request, entry_error(bad))}

      true ->
        :ok
    end
  end

  defp valid_entry?({key, value}) when is_binary(key) and is_binary(value) do
    key != "" and byte_size(key) <= @max_key_bytes and byte_size(value) <= @max_value_bytes
  end

  defp valid_entry?(_), do: false

  defp entry_error({key, value}) when is_binary(key) and is_binary(value) do
    cond do
      key == "" -> "kv key must be a non-empty string"
      byte_size(key) > @max_key_bytes -> "key exceeds #{@max_key_bytes}-byte limit"
      true -> "value exceeds #{@max_value_bytes}-byte limit"
    end
  end

  defp entry_error(_), do: "kv entries must be string pairs"

  defp fetch_instance(instance_id) do
    case Instances.get(instance_id) do
      nil -> {:error, Error.new(:not_found, "plugin instance #{instance_id} does not exist")}
      instance -> {:ok, instance}
    end
  end

  defp resolve_config_id(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{id: id} -> {:ok, id}
      nil -> {:error, Error.new(:not_found, "plugin #{slug} is not installed")}
    end
  end

  # Per-instance single-flight (Task 4) serializes writes, so read-then-write
  # is race-free in practice.
  defp check_quota(instance_id, entries) do
    keys = Enum.map(entries, &elem(&1, 0))

    existing =
      Repo.all(
        from k in Kv,
          where: k.instance_id == ^instance_id and k.key in ^keys,
          select: {k.key, k.size_bytes}
      )
      |> Map.new()

    new_keys = Enum.count(keys, &(not Map.has_key?(existing, &1)))

    delta_bytes =
      Enum.reduce(entries, 0, fn {k, _v} = e, acc ->
        acc + entry_size(e) - Map.get(existing, k, 0)
      end)

    %{keys: key_count, bytes: byte_total} = usage(instance_id)

    cond do
      new_keys > 0 and key_count + new_keys > max_keys() ->
        {:error,
         Error.new(:capability_denied, "store quota exceeded: #{max_keys()} keys per instance")}

      delta_bytes > 0 and byte_total + delta_bytes > max_bytes() ->
        {:error,
         Error.new(:capability_denied, "store quota exceeded: #{max_bytes()} bytes per instance")}

      true ->
        :ok
    end
  end

  defp entry_size({key, value}), do: byte_size(key) + byte_size(value)

  defp upsert_all(_instance, _config_id, []), do: :ok

  defp upsert_all(instance, config_id, entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(entries, fn {key, value} = entry ->
        %{
          id: Ecto.UUID.generate(),
          plugin_config_id: config_id,
          plugin_slug: instance.plugin_slug,
          instance_id: instance.id,
          key: key,
          value: value,
          size_bytes: entry_size(entry),
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.insert_all(Kv, rows,
           on_conflict: {:replace, [:value, :size_bytes, :updated_at]},
           conflict_target: [:instance_id, :key]
         ) do
      {n, _} when n >= 1 -> :ok
      _ -> {:error, Error.new(:internal, "kv write failed")}
    end
  rescue
    Ecto.ConstraintError ->
      # FK violation: the plugin was uninstalled between resolve and insert.
      {:error, Error.new(:not_found, "plugin #{instance.plugin_slug} is not installed")}
  end

  # substr() compares literally on both engines, unlike LIKE (which treats
  # `%`/`_` as wildcards and is case-insensitive for ASCII on SQLite).
  defp where_prefix(query, ""), do: query

  defp where_prefix(query, prefix) do
    # substr() counts codepoints, not graphemes.
    len = prefix |> String.to_charlist() |> length()
    from k in query, where: fragment("substr(?, 1, ?)", k.key, ^len) == ^prefix
  end

  defp where_after(query, nil), do: query
  defp where_after(query, after_key), do: from(k in query, where: k.key > ^after_key)

  defp encode_cursor(key), do: Base.url_encode64(key, padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, key} ->
        if String.valid?(key),
          do: {:ok, key},
          else: {:error, Error.new(:invalid_request, "malformed kv-list cursor")}

      :error ->
        {:error, Error.new(:invalid_request, "malformed kv-list cursor")}
    end
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(nil), do: 0

  defp store_config do
    case Application.get_env(:mydia, :runtime_config) do
      %{plugins: %{} = plugins} -> plugins
      _ -> Mydia.Config.Schema.defaults().plugins
    end
  end
end
