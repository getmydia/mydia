defmodule Mydia.Media.Posters do
  @moduledoc """
  Resolves which poster a media item displays.

  A user-chosen `poster_override` (a hosted `/generated/posters/...` path or a
  provider path) wins over the provider's `metadata.poster_path`.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{ItemWrites, MediaItem, PosterStore}
  alias Mydia.Metadata.Access, as: MetadataAccess

  @doc """
  Returns the effective poster path for a media item, or nil.

  Reads `poster_override` first, then the metadata poster path. Empty strings
  count as unset.
  """
  @spec effective_path(Mydia.Media.MediaItem.t() | map()) :: String.t() | nil
  def effective_path(item) do
    present(Map.get(item, :poster_override)) ||
      present(MetadataAccess.get_field(item, :poster_path))
  end

  @doc "Chooses a provider poster path (e.g. `/abc.jpg`) as the override."
  @spec set_provider_poster(Scope.t(), MediaItem.t(), String.t()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_provider_poster(%Scope{} = scope, %MediaItem{} = item, path) when is_binary(path) do
    with :ok <- authorize(scope, item) do
      persist(scope, item, path)
    end
  end

  @doc "Stores uploaded image bytes as the override."
  @spec set_uploaded_poster(Scope.t(), MediaItem.t(), binary()) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_uploaded_poster(%Scope{} = scope, %MediaItem{} = item, binary) when is_binary(binary) do
    with :ok <- authorize(scope, item),
         {:ok, url} <- PosterStore.write(item.id, binary) do
      case persist(scope, item, url) do
        {:ok, _} = ok ->
          ok

        error ->
          # Identical bytes map to the same file name, which the item may
          # already be using, so only a fresh file is cleaned up.
          if url != item.poster_override, do: PosterStore.delete(url)
          error
      end
    end
  end

  @doc "Clears the override so the provider's poster shows again."
  @spec reset_poster(Scope.t(), MediaItem.t()) :: {:ok, MediaItem.t()} | {:error, term()}
  def reset_poster(%Scope{} = scope, %MediaItem{} = item) do
    with :ok <- authorize(scope, item) do
      persist(scope, item, nil)
    end
  end

  defp authorize(scope, item),
    do: ItemWrites.authorize_write(scope, ItemWrites.merged_write_attrs(item, %{}))

  defp persist(scope, %MediaItem{poster_override: previous} = item, value) do
    changeset = MediaItem.poster_override_changeset(item, %{poster_override: value})

    opts = [
      actor_type: :user,
      actor_id: scope.user && scope.user.id,
      reason: "Poster changed"
    ]

    with {:ok, updated} <- ItemWrites.persist_and_audit_media_item(changeset, item, opts) do
      if previous != value, do: PosterStore.delete(previous)
      {:ok, updated}
    end
  end

  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_), do: nil
end
