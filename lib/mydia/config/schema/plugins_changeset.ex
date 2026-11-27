defmodule Mydia.Config.Schema.PluginsChangeset do
  @moduledoc """
  Changesets for the `plugins` section and the `plugin_sources` entries of
  `Mydia.Config.Schema`.
  """

  import Ecto.Changeset

  alias Mydia.Plugins.Index.Signature

  @default_index_url "https://plugins.mydia.dev/index.json"

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :fuel_enabled,
      :fuel_limit,
      :memory_limit_bytes,
      :invocation_timeout_ms,
      :schedule_timeout_ms,
      :setup_timeout_ms,
      :pool_size,
      :store_max_keys,
      :store_max_bytes,
      :page_timeout_ms,
      :page_http_timeout_ms,
      :index_url,
      :index_public_key,
      :override_dir
    ])
    |> validate_required([:fuel_enabled])
    |> validate_positive(
      ~w(fuel_limit memory_limit_bytes invocation_timeout_ms schedule_timeout_ms setup_timeout_ms)a ++
        ~w(pool_size store_max_keys store_max_bytes page_timeout_ms page_http_timeout_ms)a
    )
    |> validate_https_source(:index_url)
    |> validate_index_public_key()
  end

  defp validate_index_public_key(changeset) do
    url = get_field(changeset, :index_url)
    key = get_field(changeset, :index_public_key)

    cond do
      key not in [nil, ""] and match?({:error, _}, Signature.parse_public_key(key)) ->
        add_error(changeset, :index_public_key, "is not a minisign public key")

      url not in [nil, "", @default_index_url] and key in [nil, ""] ->
        add_error(changeset, :index_public_key, "is required when index_url is overridden")

      true ->
        changeset
    end
  end

  def source_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:url, :public_key])
    |> validate_required([:url, :public_key])
    |> validate_https_source(:url)
    |> validate_change(:public_key, fn :public_key, key ->
      case Signature.parse_public_key(key) do
        {:ok, _} -> []
        {:error, _} -> [public_key: "is not a minisign public key"]
      end
    end)
  end

  # KTD10: the index/source transport is the v1 trust anchor, so a non-HTTPS
  # source URL is rejected at config-validation time (no downgrade).
  defp validate_https_source(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      "" ->
        changeset

      url ->
        if https?(url), do: changeset, else: add_error(changeset, field, "must be an https URL")
    end
  end

  defp https?(url) when is_binary(url), do: URI.parse(url).scheme == "https"
  defp https?(_), do: false

  defp validate_positive(changeset, fields),
    do: Enum.reduce(fields, changeset, &validate_number(&2, &1, greater_than: 0))
end
