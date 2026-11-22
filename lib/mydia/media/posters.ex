defmodule Mydia.Media.Posters do
  @moduledoc """
  Resolves which poster a media item displays.

  A user-chosen `poster_override` (a hosted `/generated/posters/...` path or a
  provider path) wins over the provider's `metadata.poster_path`.
  """

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

  defp present(""), do: nil
  defp present(value) when is_binary(value), do: value
  defp present(_), do: nil
end
