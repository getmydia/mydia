defmodule MydiaWeb.ImportMediaLive.LibraryResolver do
  @moduledoc """
  Picks the library path the Import Media page opens on, from its URL params.
  """

  @doc "Resolves `params` to the id of one of `library_paths`, or its default."
  def resolve_library_path_id(params, library_paths) do
    cond do
      id = params["library_path_id"] || params["library_id"] ->
        Enum.find_value(library_paths, &(&1.id == id && &1.id)) ||
          default_library_path_id(library_paths)

      type = params["type"] || params["library_type"] ->
        resolve_library_by_type(type, library_paths) || default_library_path_id(library_paths)

      true ->
        default_library_path_id(library_paths)
    end
  end

  defp resolve_library_by_type(type, library_paths) when type in ["movies", "movie"] do
    Enum.find_value(library_paths, fn lp -> lp.default_for_movies && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :movies && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :mixed && lp.id end)
  end

  defp resolve_library_by_type(type, library_paths)
       when type in ["tv", "series", "tv_show", "shows"] do
    Enum.find_value(library_paths, fn lp -> lp.default_for_series && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :series && lp.id end) ||
      Enum.find_value(library_paths, fn lp -> lp.type == :mixed && lp.id end)
  end

  defp resolve_library_by_type(_type, _library_paths), do: nil

  # Scanning and review work on one library path at a time. On mount the
  # page-level tabs default to the first importable path; after that,
  # select_library/2 changes the shared page context.
  defp default_library_path_id([%{id: id} | _rest]), do: id
  defp default_library_path_id([]), do: nil
end
