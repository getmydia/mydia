defmodule Mydia.Media.Refresh do
  @moduledoc """
  Owns refreshing a single media item's metadata from its provider.

  This module is the single source of truth for the refresh flow. Before it
  existed the same sequence was written three times (the Oban job, the `Media`
  context, and the show LiveView) and the copies had drifted apart, which is
  how a crash reached production: the job resolved providers using
  `media_item.metadata["id"]`, and `%MediaMetadata{}` does not implement
  `Access`.
  """

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  @typedoc "A resolved provider id and the provider that owns it."
  @type resolution :: {pos_integer() | nil, :tvdb | :tmdb | nil}

  @doc """
  Resolves which provider and id a refresh should fetch from.

  `metadata_source` is the authoritative provenance recorded when an item was
  matched under per-library provider selection, so it wins even when a
  back-filled id for the other provider is also present. Only when it is absent
  do we fall back to the legacy TVDB-precedence rule, and only after that to the
  id stored inside the metadata blob.

  Returns the id as an **integer**. Callers building an HTTP path convert with
  `to_string/1`.
  """
  @spec resolve_provider(MediaItem.t()) :: resolution()
  def resolve_provider(%MediaItem{metadata_source: :tmdb, tmdb_id: id}) when not is_nil(id),
    do: {id, :tmdb}

  def resolve_provider(%MediaItem{metadata_source: :tvdb, tvdb_id: id}) when not is_nil(id),
    do: {id, :tvdb}

  def resolve_provider(%MediaItem{tvdb_id: id}) when not is_nil(id), do: {id, :tvdb}
  def resolve_provider(%MediaItem{tmdb_id: id}) when not is_nil(id), do: {id, :tmdb}

  def resolve_provider(%MediaItem{metadata: %MediaMetadata{} = metadata}) do
    case normalize_id(metadata.id) || normalize_id(metadata.provider_id) do
      nil -> {nil, nil}
      id -> {id, :tmdb}
    end
  end

  def resolve_provider(%MediaItem{}), do: {nil, nil}

  # Struct field access, never Access syntax. `provider_id` is frequently the
  # empty string because `MetadataType.map_to_struct/1` defaults it to
  # `to_string(data[:id] || "")`, and "" is truthy in Elixir.
  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_id(_), do: nil
end
