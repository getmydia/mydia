defmodule MydiaWeb.StreamLink do
  @moduledoc """
  Stream links: per-file URLs an external player can open without a session.

  The path carries a `Phoenix.Token` over `{user_id, media_file_id}`. Links
  never expire, so rotating `secret_key_base` is the only way to revoke them
  all at once. That is acceptable because the token is not the whole check:
  `MydiaWeb.StreamLinkController` re-authorizes the user against the file on
  every request, so a deleted user, a new restriction or a trashed file stops
  the link immediately.

  The trailing filename is cosmetic. Players show it as a title and use the
  extension to guess the container; the server ignores it.
  """

  use MydiaWeb, :verified_routes

  alias Mydia.Library.MediaFile

  @salt "external stream"

  @spec path(String.t(), MediaFile.t()) :: String.t()
  def path(user_id, %MediaFile{id: file_id} = file) when is_binary(user_id) do
    token = Phoenix.Token.sign(MydiaWeb.Endpoint, @salt, {user_id, file_id})
    ~p"/stream/#{token}/#{MediaFile.display_name(file)}"
  end

  @spec verify(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(MydiaWeb.Endpoint, @salt, token, max_age: :infinity) do
      {:ok, {user_id, file_id}} when is_binary(user_id) and is_binary(file_id) ->
        {:ok, {user_id, file_id}}

      _ ->
        :error
    end
  end
end
