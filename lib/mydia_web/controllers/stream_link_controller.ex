defmodule MydiaWeb.StreamLinkController do
  @moduledoc """
  Serves the raw file behind a `MydiaWeb.StreamLink` to an external player.

  Every failure is the same bare 404, so a caller holding a link cannot tell a
  bad token from a revoked permission or a deleted file.
  """

  use MydiaWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias MydiaWeb.Api.RangeHelper
  alias MydiaWeb.MediaAccess
  alias MydiaWeb.StreamLink

  require Logger

  def show(conn, %{"token" => token}) do
    with {:ok, {user_id, file_id}} <- StreamLink.verify(token),
         %Accounts.User{} = user <- Accounts.get_user_by_id(user_id),
         %MediaFile{} = file <- get_active_file(file_id),
         :ok <- MediaAccess.authorize_media_file_for_scope(Scope.for_user(user), file),
         {:ok, path} <- on_disk_path(file) do
      # The URL is a per-user bearer credential; keep shared caches away from it.
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> RangeHelper.send_file_ranged(path)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  # Same preloads as StreamController.stream/2: a TV file reaches its show only
  # through the episode, which FileAccess needs to apply restrictions.
  defp get_active_file(file_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(file_id) do
      Repo.one(
        from(mf in MediaFile,
          where: mf.id == ^uuid and is_nil(mf.trashed_at),
          preload: [:media_item, :library_path, episode: :media_item]
        )
      )
    end
  end

  defp on_disk_path(file) do
    case MediaFile.absolute_path(file) do
      nil ->
        :error

      path ->
        if File.exists?(path) do
          {:ok, path}
        else
          Logger.warning("Stream link for media_file #{file.id}: not on disk at #{path}")
          :error
        end
    end
  end
end
