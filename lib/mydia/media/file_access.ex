defmodule Mydia.Media.FileAccess do
  @moduledoc """
  Authorizes a directly-resolved `media_files` row against a scope.

  Most reads need nothing from this module, because they load through
  `Mydia.Media.get_media_item!/3` or `Mydia.Media.get_episode!/3`, which are
  already scoped. This exists for the paths that resolve a file row by its own
  id: REST controllers (through `MydiaWeb.MediaAccess`), GraphQL resolvers,
  the p2p server and transcode jobs.

  A TV `media_file` has `media_item_id` set to NULL and reaches its show only
  through `episode_id`. A check written against the column alone passes every
  episode in the library while looking correct, so resolution here goes through
  the episode when the direct id is absent.
  """

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.FileAccess.MissingScopeError
  alias Mydia.Media.MediaItem
  alias Mydia.Media.Restrictions
  alias Mydia.Repo

  @doc """
  Returns `:ok` when the scope may reach this file, `:denied` otherwise. An
  unresolvable file is denied, and so is a missing scope.
  """
  @spec authorize(Scope.t() | nil, MediaFile.t()) :: :ok | :denied
  def authorize(%Scope{allowed_categories: nil, max_content_age: nil}, %MediaFile{}), do: :ok

  def authorize(%Scope{} = scope, %MediaFile{} = file) do
    case owning_item(file) do
      %MediaItem{} = item -> if Restrictions.visible?(item, scope), do: :ok, else: :denied
      nil -> :denied
    end
  end

  # No scope means no auth boundary ran. Deny rather than assume, and say so:
  # for an unrestricted account this denial is a 404 that looks exactly like a
  # missing file, so nothing else would ever surface it. The telemetry event is
  # what tests assert on; CrashReporter.report/3 is a no-op while crash
  # reporting is disabled.
  def authorize(_scope, %MediaFile{}) do
    report_missing_scope()
    :denied
  end

  @doc """
  Loads a file by id and authorizes it. A missing row and a malformed id are
  `:denied`, the same answer as a hidden file, so callers cannot tell them
  apart and neither can the client.
  """
  @spec authorize_id(Scope.t() | nil, String.t()) :: {:ok, MediaFile.t()} | :denied
  def authorize_id(scope, media_file_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(media_file_id),
         %MediaFile{} = file <- Repo.get(MediaFile, uuid),
         :ok <- authorize(scope, file) do
      {:ok, file}
    else
      _ -> :denied
    end
  end

  defp report_missing_scope do
    {:current_stacktrace, [_process_info | stacktrace]} =
      Process.info(self(), :current_stacktrace)

    :telemetry.execute([:mydia, :media_access, :missing_scope], %{count: 1}, %{
      stacktrace: stacktrace
    })

    Mydia.CrashReporter.report(%MissingScopeError{}, stacktrace, %{component: "media_access"})
  end

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
