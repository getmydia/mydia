defmodule MydiaWeb.PosterCandidateController do
  @moduledoc """
  Serves the image files the poster picker's "From folder" tab shows as
  thumbnails.

  The route sits in the admin scope, and this controller checks
  `can_update_media?/1` again before reading, because
  `Mydia.Media.Posters.read_candidate/3` does no authorization of its own.
  Only an exact member of the item's candidate list is readable; anything
  else is a 404.
  """

  use MydiaWeb, :controller

  alias Mydia.Accounts.Authorization
  alias Mydia.Media
  alias Mydia.Media.{PosterStore, Posters}

  @content_types %{
    "jpg" => "image/jpeg",
    "png" => "image/png",
    "webp" => "image/webp"
  }

  def show(conn, %{"id" => id, "library_path_id" => lp_id, "path" => segments}) do
    scope = conn.assigns.current_scope

    with true <- Authorization.can_update_media?(scope),
         {:ok, item} <- fetch_item(scope, id),
         {:ok, bytes} <- Posters.read_candidate(item, lp_id, Enum.join(segments, "/")),
         {:ok, ext} <- PosterStore.detect_format(bytes) do
      conn
      |> put_resp_content_type(Map.fetch!(@content_types, ext), nil)
      |> put_resp_header("cache-control", "private, max-age=60")
      |> send_resp(200, bytes)
    else
      false -> send_resp(conn, 403, "")
      _ -> send_resp(conn, 404, "")
    end
  end

  defp fetch_item(scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      {:ok, Media.get_media_item!(scope, uuid)}
    end
  rescue
    Ecto.NoResultsError -> :error
  end
end
