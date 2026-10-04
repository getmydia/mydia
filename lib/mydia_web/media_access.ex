defmodule MydiaWeb.MediaAccess do
  @moduledoc """
  Web-facing entry to `Mydia.Media.FileAccess`.

  REST controllers call `authorize_media_file/2`, which reads the scope off
  `conn.assigns`. GraphQL resolvers call `authorize_media_file_for_scope/2`
  with `resolution.context[:current_scope]`. Both answer exactly as
  `Mydia.Media.FileAccess.authorize/2`, including the missing-scope report.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Library.MediaFile
  alias Mydia.Media.FileAccess

  @spec authorize_media_file(Plug.Conn.t(), MediaFile.t()) :: :ok | :denied
  def authorize_media_file(conn, %MediaFile{} = file),
    do: FileAccess.authorize(conn.assigns[:current_scope], file)

  @spec authorize_media_file_for_scope(Scope.t() | nil, MediaFile.t()) :: :ok | :denied
  def authorize_media_file_for_scope(scope, %MediaFile{} = file),
    do: FileAccess.authorize(scope, file)
end
