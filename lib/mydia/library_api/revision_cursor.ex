defmodule Mydia.LibraryApi.RevisionCursor do
  @moduledoc """
  The opaque cursor for the latest-state media revision feed.

  Encodes one database-generated `media_item_revisions.revision` as the
  versioned payload `v1:<positive-decimal>`, base64url and unpadded, so the
  value is safe in a JSON string and has no characters that need escaping in a
  shell or URL. The version prefix is what makes an old cursor fail closed: the
  beta `mediaItems` timestamp cursor decodes to a payload this module does not
  recognize, so a consumer that outlived that contract resyncs instead of
  paging from an arbitrary position.
  """

  @prefix "v1:"

  @spec encode(pos_integer()) :: String.t()
  def encode(revision) when is_integer(revision) and revision > 0 do
    Base.url_encode64(@prefix <> Integer.to_string(revision), padding: false)
  end

  @spec decode(String.t()) :: {:ok, pos_integer()} | :error
  def decode(cursor) when is_binary(cursor) do
    with {:ok, payload} <- Base.url_decode64(cursor, padding: false),
         @prefix <> decimal <- payload,
         {revision, ""} <- Integer.parse(decimal),
         true <- revision > 0 do
      {:ok, revision}
    else
      _ -> :error
    end
  end

  def decode(_cursor), do: :error
end
