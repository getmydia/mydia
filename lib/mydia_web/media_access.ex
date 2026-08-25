defmodule MydiaWeb.MediaAccess do
  @moduledoc """
  Authorizes a directly-resolved `media_files` row against the caller's scope.

  Most endpoints need nothing from this module, because they load through
  `Mydia.Media.get_media_item!/3` or `Mydia.Media.get_episode!/3`, which are
  already scoped and raise `Ecto.NoResultsError` for a hidden id. This exists
  for the endpoints that resolve a file row by its own id, bypassing that
  scoped lookup — both REST controllers (via `authorize_media_file/2`, which
  reads the scope off `conn.assigns`) and GraphQL resolvers (via
  `authorize_media_file_for_scope/2`, which takes the scope directly, since a
  resolver carries `resolution.context[:current_scope]` rather than a conn).

  A TV `media_file` has `media_item_id` set to NULL and reaches its show only
  through `episode_id`. A check written against the column alone passes every
  episode in the library while looking correct, so resolution here goes through
  the episode when the direct id is absent.
  """

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Media.Restrictions
  alias Mydia.Repo

  @doc """
  Returns `:ok` when the connection's scope may reach this file, `:denied`
  otherwise. An unresolvable file is denied.
  """
  @spec authorize_media_file(Plug.Conn.t(), MediaFile.t()) :: :ok | :denied
  def authorize_media_file(conn, %MediaFile{} = file) do
    authorize(conn.assigns[:current_scope], file)
  end

  @doc """
  Same as `authorize_media_file/2`, for callers that already hold a
  `Mydia.Accounts.Scope` rather than a `Plug.Conn` — the GraphQL resolvers,
  which carry the scope on `resolution.context[:current_scope]` instead of
  conn assigns.
  """
  @spec authorize_media_file_for_scope(Scope.t() | nil, MediaFile.t()) :: :ok | :denied
  def authorize_media_file_for_scope(scope, %MediaFile{} = file) do
    authorize(scope, file)
  end

  defp authorize(%Scope{allowed_categories: nil, max_content_age: nil}, _file), do: :ok

  defp authorize(%Scope{} = scope, %MediaFile{} = file) do
    case owning_item(file) do
      %MediaItem{} = item -> if Restrictions.visible?(item, scope), do: :ok, else: :denied
      nil -> :denied
    end
  end

  # No scope assigned means no auth boundary ran. Deny rather than assume.
  defp authorize(_scope, _file), do: :denied

  defp owning_item(%MediaFile{media_item_id: id}) when is_binary(id), do: Repo.get(MediaItem, id)

  defp owning_item(%MediaFile{episode_id: episode_id}) when is_binary(episode_id) do
    from(m in MediaItem,
      join: e in Episode,
      on: e.media_item_id == m.id,
      where: e.id == ^episode_id,
      select: m
    )
    |> Repo.one()
  end

  defp owning_item(_file), do: nil
end
