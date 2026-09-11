defmodule MydiaWeb.LibrarySchema.Resolvers.LibraryWrites do
  @moduledoc """
  Resolves `addMovie`, `addTvShow` and `removeMediaItem`.

  Adding goes through `Mydia.Media.Add.from_provider/4`, the entry point the
  search page's Add button uses, then `Mydia.Search.maybe_queue_search/2` for
  `searchNow`, as the UI does. Removing is `Mydia.Media.delete_media_item/2`.
  """

  alias Mydia.LibraryApi.Principal
  alias Mydia.Media
  alias Mydia.Media.Add
  alias Mydia.Search
  alias MydiaWeb.LibrarySchema.Loaders
  alias MydiaWeb.LibrarySchema.UserError

  @spec add_movie(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def add_movie(_parent, %{input: input}, resolution) do
    add({:tmdb, input.tmdb_id}, :movie, input, resolution.context.principal)
  end

  @spec add_tv_show(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def add_tv_show(_parent, %{input: input}, resolution) do
    case show_ref(input) do
      {:ok, ref} -> add(ref, :tv_show, input, resolution.context.principal)
      {:error, error} -> {:ok, add_failure([error])}
    end
  end

  @spec remove_media_item(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def remove_media_item(_parent, %{input: input}, resolution) do
    opts =
      Principal.actor_opts(resolution.context.principal) ++
        [delete_files: input[:delete_files] == true]

    with {:ok, item} <- Loaders.item(input.id, ["input", "id"]),
         {:ok, _deleted, _disk_errors} <- Media.delete_media_item(item, opts) do
      {:ok, %{removed_id: item.id, user_errors: []}}
    else
      {:error, %UserError{} = error} ->
        {:ok, %{removed_id: nil, user_errors: [error]}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:ok, %{removed_id: nil, user_errors: UserError.from_changeset(changeset, ["input"])}}
    end
  end

  defp add(ref, media_type, input, principal) do
    case add_opts(input, principal) do
      {:ok, opts} ->
        ref
        |> Add.from_provider(media_type, nil, opts)
        |> added(input[:search_now] == true)

      {:error, error} ->
        {:ok, add_failure([error])}
    end
  end

  defp added({:ok, item}, search_now?) do
    :ok = Search.maybe_queue_search(item, search_now?)
    {:ok, %{media_item: Loaders.item_map(item.id), user_errors: []}}
  end

  # The existing item comes back beside the error, so a client that only needed
  # the title present can carry on with its id.
  defp added({:error, {:already_in_library, existing}}, _search_now?) do
    error = UserError.new(:already_in_library, "#{existing.title} is already in the library")
    {:ok, %{media_item: Loaders.item_map(existing.id), user_errors: [error]}}
  end

  defp added({:error, {:metadata, _reason}}, _search_now?) do
    error =
      UserError.new(:metadata_unavailable, "The metadata relay could not provide this title")

    {:ok, add_failure([error])}
  end

  defp added({:error, {:changeset, changeset}}, _search_now?) do
    {:ok, add_failure(UserError.from_changeset(changeset, ["input"]))}
  end

  defp add_opts(input, principal) do
    with {:ok, profile_id} <-
           optional_id(input[:quality_profile_id], ["input", "qualityProfileId"]),
         {:ok, path_id} <- optional_id(input[:library_path_id], ["input", "libraryPathId"]) do
      opts =
        principal
        |> Principal.actor_opts()
        |> Keyword.put(:monitored, input[:monitored] != false)
        |> put_present(:quality_profile_id, profile_id)
        |> put_present(:library_path_id, path_id)
        |> put_present(:season_monitoring, season_monitoring(input[:season_monitoring]))

      {:ok, opts}
    end
  end

  defp show_ref(%{tvdb_id: tvdb_id}) when is_integer(tvdb_id), do: {:ok, {:tvdb, tvdb_id}}
  defp show_ref(%{tmdb_id: tmdb_id}) when is_integer(tmdb_id), do: {:ok, {:tmdb, tmdb_id}}

  defp show_ref(_input),
    do: {:error, UserError.new(:invalid_input, "Give tvdbId or tmdbId", ["input"])}

  defp optional_id(nil, _field), do: {:ok, nil}
  defp optional_id(value, field), do: UserError.cast_id(value, field)

  # Add and Media.create_media_item/2 take the preset as a string.
  defp season_monitoring(nil), do: nil
  defp season_monitoring(preset), do: Atom.to_string(preset)

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp add_failure(errors), do: %{media_item: nil, user_errors: errors}
end
