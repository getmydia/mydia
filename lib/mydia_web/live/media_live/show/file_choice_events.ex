defmodule MydiaWeb.MediaLive.Show.FileChoiceEvents do
  @moduledoc """
  "Choose files…" on a manual-search result: lists the torrent's files with
  `Mydia.Downloads.preview_files/2`, lets the operator adjust Mydia's picks
  in a folder tree, and grabs only the chosen files.

  `file_choice` is nil while no modal is open, otherwise
  a `FileChoice` (`ref, title, status, preview, files, selected`), where
  `status` is `:loading`, `:ready` or `{:error, reason}`. The preview (which can hold a
  `.torrent` body) lives only there, and is dropped when the modal closes.
  Nothing is added to the client before the confirm, so closing undoes
  nothing.

  See `design/specs/2026-11-28-torrent-file-tree-design.md`, "Part 2 > UI".
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]
  import MydiaWeb.FileTreeComponents, only: [toggle_target: 1]

  alias Mydia.Downloads
  alias Mydia.Downloads.{Client, FileSelection, FileTree}
  alias Mydia.Downloads.Queue.FilePreview
  alias Mydia.Indexers.SearchResult
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.MediaLive.Show.FileChoice
  alias MydiaWeb.MediaLive.Show.SearchEvents

  require Logger

  # The release is already downloading or on disk: the row says so, as a plain
  # Download would, and the modal offers no download.
  @duplicate_reasons [:duplicate_download, :already_have_files]

  @events ~w(choose_files toggle_files toggle_all_files confirm_file_choice
             cancel_file_choice download_auto_from_choice)

  @doc "True for the events `handle_event/3` takes, for the LiveView's dispatch."
  defguard is_file_choice_event(event) when event in @events

  @doc "Runs one of the modal's events (see `is_file_choice_event/1`)."
  def handle_event("choose_files", params, socket), do: choose_files(params, socket)
  def handle_event("toggle_files", params, socket), do: toggle_files(params, socket)
  def handle_event("toggle_all_files", _params, socket), do: toggle_all_files(socket)
  def handle_event("confirm_file_choice", _params, socket), do: confirm_file_choice(socket)
  def handle_event("cancel_file_choice", _params, socket), do: {:noreply, close(socket)}
  def handle_event("download_auto_from_choice", _params, socket), do: download_auto(socket)

  # Opens the modal for the result `ref` names and starts listing its files.
  defp choose_files(%{"ref" => ref}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket),
         %SearchResult{} = result <- SearchEvents.find_search_result(socket, ref) do
      {result_with_metadata, opts} = SearchEvents.grab_opts(result, socket)

      {:noreply,
       socket
       |> assign(:file_choice, %FileChoice{ref: ref, title: result.title})
       |> start_async(:file_preview, fn ->
         {ref, Downloads.preview_files(result_with_metadata, opts)}
       end)}
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      nil ->
        {:noreply, release_gone(socket)}
    end
  end

  defp choose_files(_params, socket), do: {:noreply, socket}

  @doc """
  The preview's result. One for a modal that was closed, or reopened on
  another release, is dropped.
  """
  def handle_preview_async({:ok, {ref, result}}, socket) do
    case socket.assigns.file_choice do
      %{ref: ^ref, status: :loading} = choice ->
        {:noreply,
         socket
         |> assign(:file_choice, apply_preview(choice, result))
         |> mark_duplicate(ref, result)}

      _closed_or_other ->
        {:noreply, socket}
    end
  end

  def handle_preview_async({:exit, reason}, socket) do
    case socket.assigns.file_choice do
      %{status: :loading} = choice ->
        Logger.warning("File preview crashed", reason: inspect(reason_kind(reason)))
        {:noreply, assign(socket, :file_choice, %{choice | status: {:error, :crashed}})}

      _closed ->
        {:noreply, socket}
    end
  end

  defp toggle_files(params, socket) do
    case toggle_target(params) do
      nil -> {:noreply, socket}
      target -> {:noreply, change_selection(socket, &FileTree.toggle(&1, &2, target))}
    end
  end

  defp toggle_all_files(socket),
    do: {:noreply, change_selection(socket, &FileTree.toggle_all/2)}

  # Grabs the chosen files. The button is disabled without an importable
  # video; a forged confirm is refused here the same way, so the grab never
  # fails on `:no_importable_file`.
  defp confirm_file_choice(socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket),
         %{status: :ready, preview: preview, files: files, selected: selected, ref: ref} <-
           socket.assigns.file_choice,
         indexes = selected |> MapSet.to_list() |> Enum.sort(),
         true <- FileSelection.keeps_video?(files, indexes),
         {:found, %SearchResult{} = result} <-
           {:found, SearchEvents.find_search_result(socket, ref)} do
      SearchEvents.grab_search_result(
        result,
        assign(socket, :file_choice, nil),
        file_preview: preview,
        only_files: indexes
      )
    else
      {:unauthorized, socket} -> {:noreply, socket}
      {:found, nil} -> {:noreply, socket |> assign(:file_choice, nil) |> release_gone()}
      _not_ready_or_no_video -> {:noreply, socket}
    end
  end

  # After a failed preview: the plain Download, with Mydia's own picks.
  defp download_auto(socket) do
    case socket.assigns.file_choice do
      %{ref: ref} -> SearchEvents.download_from_search(%{"ref" => ref}, close(socket))
      nil -> {:noreply, socket}
    end
  end

  @doc "True when a failed preview found the release already downloading or on disk."
  def duplicate?(reason), do: reason in @duplicate_reasons

  @doc "Why the file list could not be shown, for the modal."
  def error_message(:duplicate_download), do: gettext("Already downloading")
  def error_message(:already_have_files), do: gettext("These files are already in the library.")

  def error_message(:unsupported),
    do: gettext("The download client cannot choose files for this release.")

  def error_message(:no_files), do: gettext("The torrent did not list any files.")
  def error_message(_reason), do: gettext("Couldn't fetch the file list.")

  defp apply_preview(choice, {:ok, %FilePreview{} = preview}) do
    %{
      choice
      | status: :ready,
        preview: preview,
        files: FilePreview.files(preview),
        selected: FilePreview.auto_selected(preview)
    }
  end

  defp apply_preview(choice, {:error, reason}) do
    Logger.info("File preview unavailable",
      title: choice.title,
      reason: inspect(reason_kind(reason))
    )

    %{choice | status: {:error, reason}}
  end

  defp mark_duplicate(socket, ref, {:error, reason}) when reason in @duplicate_reasons do
    case SearchEvents.find_search_result(socket, ref) do
      %SearchResult{download_url: url} ->
        SearchEvents.mark_result(socket, url, %{duplicate: true})

      nil ->
        socket
    end
  end

  defp mark_duplicate(socket, _ref, _result), do: socket

  # Only the kind of failure is logged: a fetch error's message or an exit's
  # stacktrace can carry the release URL, and with it a tracker passkey.
  defp reason_kind(reason) when is_atom(reason), do: reason

  defp reason_kind(%Client.Error{type: type}), do: {:client_error, type}

  defp reason_kind(%module{}), do: module
  defp reason_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp reason_kind(_reason), do: :other

  defp change_selection(socket, fun) do
    case socket.assigns.file_choice do
      %{status: :ready, files: files, selected: selected} = choice ->
        assign(socket, :file_choice, %{choice | selected: fun.(selected, files)})

      _not_ready ->
        socket
    end
  end

  defp close(socket) do
    socket
    |> cancel_async(:file_preview)
    |> assign(:file_choice, nil)
  end

  defp release_gone(socket) do
    assign(
      socket,
      :download_error,
      gettext("That release is no longer in the results. Search again.")
    )
  end
end
