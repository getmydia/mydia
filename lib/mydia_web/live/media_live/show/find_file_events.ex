defmodule MydiaWeb.MediaLive.Show.FindFileEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, connected?: 1]

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 2]

  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library
  alias Mydia.Library.CandidateSuggestions
  alias Mydia.Library.ImportRun
  alias Mydia.Media
  alias Mydia.Settings
  alias MydiaWeb.Live.Authorization

  @refresh_ms 1_000

  def assign_defaults(socket) do
    assign(socket,
      find_file_target: nil,
      find_file_query: "",
      find_file_suggestions: [],
      find_file_runs: %{},
      find_file_refresh_pending: false
    )
  end

  def open(params, socket) do
    with :ok <- Authorization.authorize_update_media(socket),
         {:ok, target} <- target(params, socket) do
      unsubscribe_all(socket)

      {:noreply,
       socket
       |> assign(find_file_target: target, find_file_query: "", find_file_runs: %{})
       |> refresh()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      :error -> {:noreply, put_flash(socket, :error, "That episode is not on this page")}
    end
  end

  def close(_params, socket) do
    unsubscribe_all(socket)
    {:noreply, assign_defaults(socket)}
  end

  def search(%{"query" => query}, socket) do
    {:noreply, socket |> assign(:find_file_query, query) |> refresh()}
  end

  def scan(_params, socket) do
    with :ok <- Authorization.authorize_update_media(socket),
         %{} = target <- socket.assigns.find_file_target do
      socket =
        target
        |> Library.start_review_scans(socket.assigns.current_user.id)
        |> Enum.reject(&Map.has_key?(socket.assigns.find_file_runs, &1.id))
        |> Enum.reduce(socket, &track_run/2)

      {:noreply, socket}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      nil -> {:noreply, socket}
    end
  end

  def attach(%{"candidate-id" => candidate_id}, socket) do
    with :ok <- Authorization.authorize_update_media(socket),
         %{} = target <- socket.assigns.find_file_target do
      case Library.attach_candidate(candidate_id, target) do
        {:ok, media_file} ->
          unsubscribe_all(socket)

          {:noreply,
           socket
           |> assign_defaults()
           |> assign(
             :media_item,
             load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)
           )
           |> put_flash(:info, "Attached #{Path.basename(media_file.relative_path)}")}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, error_message(reason)) |> refresh()}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
      nil -> {:noreply, socket}
    end
  end

  # Progress for a run this dialog started. Re-query at most once a second;
  # a large library broadcasts far more often than that.
  def run_progress(run, socket) do
    if Map.has_key?(socket.assigns.find_file_runs, run.id) do
      {:noreply, socket |> settle_run(run) |> schedule_refresh()}
    else
      {:noreply, socket}
    end
  end

  def deferred_refresh(socket) do
    {:noreply, socket |> assign(:find_file_refresh_pending, false) |> refresh()}
  end

  # Subscribe, then re-read the run: one that finished before the subscribe
  # already sent its terminal broadcast, so it settles here instead.
  defp track_run(run, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))
    end

    socket =
      assign(
        socket,
        :find_file_runs,
        Map.put(socket.assigns.find_file_runs, run.id, library_name(run.library_path_id))
      )

    case Library.get_import_run(run.id) do
      %ImportRun{status: status} = current ->
        if status in ImportRun.active_statuses(),
          do: socket,
          else: socket |> settle_run(current) |> schedule_refresh()

      nil ->
        socket |> drop_run(run) |> schedule_refresh()
    end
  end

  defp settle_run(socket, run) do
    cond do
      run.status in ImportRun.active_statuses() ->
        socket

      run.status == :failed ->
        socket
        |> drop_run(run)
        |> put_flash(:error, "Scan failed: #{run.error}")

      true ->
        drop_run(socket, run)
    end
  end

  defp drop_run(socket, run) do
    Phoenix.PubSub.unsubscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))
    assign(socket, :find_file_runs, Map.delete(socket.assigns.find_file_runs, run.id))
  end

  defp unsubscribe_all(socket) do
    Enum.each(socket.assigns.find_file_runs, fn {run_id, _name} ->
      Phoenix.PubSub.unsubscribe(Mydia.PubSub, ImportRunJob.progress_topic(run_id))
    end)
  end

  defp schedule_refresh(%{assigns: %{find_file_refresh_pending: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :find_file_refresh, @refresh_ms)
    assign(socket, :find_file_refresh_pending, true)
  end

  defp refresh(%{assigns: %{find_file_target: nil}} = socket), do: socket

  defp refresh(socket) do
    suggestions =
      CandidateSuggestions.suggest_for(socket.assigns.find_file_target,
        query: socket.assigns.find_file_query
      )

    assign(socket, :find_file_suggestions, suggestions)
  end

  defp target(%{"episode-id" => episode_id}, socket) do
    media_item = socket.assigns.media_item

    with {:ok, _uuid} <- Ecto.UUID.cast(episode_id),
         %{media_item_id: id} = episode when id == media_item.id <-
           Media.get_episode!(socket.assigns.current_scope, episode_id, preload: [:media_item]) do
      {:ok, episode}
    else
      _other -> :error
    end
  rescue
    Ecto.NoResultsError -> :error
  end

  defp target(_params, %{assigns: %{media_item: %{type: "movie"} = movie}}), do: {:ok, movie}
  defp target(_params, _socket), do: :error

  # A library path deleted while its scan starts must not crash the dialog.
  defp library_name(library_path_id) do
    Settings.get_library_path!(library_path_id).path
  rescue
    Ecto.NoResultsError -> "a removed library"
  end

  defp error_message({:duplicate_path, _, _}), do: "That file was just taken by another item"
  defp error_message({:candidate_missing, _}), do: "That file was just taken by another item"

  defp error_message({:incompatible_media_type, _}),
    do: "That file is not the right kind for this item"

  defp error_message(:file_missing), do: "That file is no longer on disk"
  defp error_message(:queued), do: "That file is already being imported or deleted"
  defp error_message({:library_path_missing, _}), do: "That file's library is gone"

  defp error_message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> Enum.map_join("; ", fn {field, msgs} ->
        "#{field} #{Enum.join(List.wrap(msgs), ", ")}"
      end)

    "Could not attach: #{details}"
  end

  defp error_message(_reason), do: "Could not attach that file"
end
