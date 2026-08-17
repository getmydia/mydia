defmodule MydiaWeb.ReviewMediaLive.Index do
  @moduledoc """
  Review: work the unresolved files of one library, grouped by series/season.

  There is no pagination and no session state: the group is a live query over
  the inbox (`Library.group_inbox_files/1`), re-read after every mutation, so
  approving a row removes it with nothing to persist.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Settings}
  alias Mydia.Library.ImportRun

  @impl true
  def mount(_params, _session, socket) do
    library_paths =
      Settings.list_library_paths()
      |> Enum.filter(&ImportRun.importable_type?(&1.type))
      |> Enum.map(fn path ->
        %{
          id: path.id,
          path: path.path,
          type: path.type,
          unresolved: Library.count_inbox_files(library_path_id: path.id)
        }
      end)

    {:ok,
     socket
     |> assign(:page_title, "Review")
     |> assign(:library_paths, library_paths)
     |> assign(:selected_library_path_id, default_library_path_id(library_paths))
     |> load_group()}
  end

  @impl true
  def handle_event("select_library", %{"library_path_id" => id}, socket) do
    if Enum.any?(socket.assigns.library_paths, &(&1.id == id)) do
      {:noreply, socket |> assign(:selected_library_path_id, id) |> load_group()}
    else
      {:noreply, socket}
    end
  end

  defp default_library_path_id([]), do: nil

  defp default_library_path_id(paths) do
    paths |> Enum.max_by(& &1.unresolved) |> Map.fetch!(:id)
  end

  defp load_group(%{assigns: %{selected_library_path_id: nil}} = socket) do
    assign(socket, :group, %{series: [], movies: [], unmatched: [], wrong_library: []})
  end

  defp load_group(socket) do
    group = Library.group_inbox_files(socket.assigns.selected_library_path_id)
    assign(socket, :group, group)
  end

  defp total_unresolved(%{
         series: series,
         movies: movies,
         unmatched: unmatched,
         wrong_library: wrong
       }) do
    series_count =
      Enum.reduce(series, 0, fn s, acc ->
        acc + Enum.reduce(s.seasons, 0, fn season, a2 -> a2 + length(season.episodes) end)
      end)

    series_count + length(movies) + length(unmatched) + length(wrong)
  end
end
