defmodule Mydia.LibraryApi.Cursor do
  @moduledoc """
  The opaque `mediaItems` cursor.

  Encodes the `{updated_at, id}` pair the keyset query compares against.
  `updated_at` is `:utc_datetime`, so second precision round-trips exactly and
  the strict `>` / `==` comparison in `Mydia.Media.list_items_page/1` stays
  correct across a page boundary.

  Base64url without padding, so the value is safe in a JSON string and has no
  characters that need escaping in a shell or URL.
  """

  @spec encode(DateTime.t(), String.t()) :: String.t()
  def encode(%DateTime{} = updated_at, id) when is_binary(id) do
    Base.url_encode64("#{DateTime.to_iso8601(updated_at)}|#{id}", padding: false)
  end

  @spec decode(String.t()) :: {:ok, {DateTime.t(), String.t()}} | :error
  def decode(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [timestamp, id] <- String.split(decoded, "|", parts: 2),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {updated_at, id}}
    else
      _ -> :error
    end
  end

  def decode(_cursor), do: :error
end
