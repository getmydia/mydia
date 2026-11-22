defmodule MydiaWeb.MediaLive.Show.PosterPicker do
  @moduledoc """
  The poster picker on the media detail page: choose a provider poster
  (Browse), upload an image (Upload) or use an image file from the item's
  folder (From folder), or go back to the provider's default (Reset).

  The parent mounts it only while it is open and closes it with the
  `close_poster_picker` event (Cancel, Escape or a backdrop click). After a
  successful write it sends `{:poster_changed, item}` to the parent, which
  reloads the item.

  Selections are indexes into lists this component holds on the server, so
  the client never names a poster path or a file. Every write checks
  `Mydia.Accounts.Authorization.can_update_media?/1` again. The tabs render
  in `MydiaWeb.MediaLive.Show.PosterPicker.Tabs`.
  """

  use MydiaWeb, :live_component

  import MydiaWeb.MediaLive.Show.PosterPicker.Tabs

  alias Mydia.Accounts.Authorization
  alias Mydia.Media.Posters
  alias Mydia.Metadata
  alias MydiaWeb.MediaLive.Show.Loaders

  @tabs %{"browse" => :browse, "upload" => :upload, "folder" => :folder}

  # Parent-side handlers, called from the media LiveView, which owns whether
  # the picker is mounted.

  @doc "Mounts the picker, for users who may edit the item."
  def open(socket),
    do: {:noreply, assign(socket, :poster_picker_open, socket.assigns.can_update_media)}

  @doc "Unmounts the picker."
  def close(socket), do: {:noreply, assign(socket, :poster_picker_open, false)}

  @doc "Reloads the item after the picker saved or reset the poster."
  def changed(socket) do
    media_item =
      Loaders.load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)

    {:noreply,
     socket
     |> assign(:media_item, media_item)
     |> assign(:poster_picker_open, false)
     |> put_flash(:info, gettext("Poster updated"))}
  end

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       started?: false,
       tab: :browse,
       browse: :loading,
       browse_results: [],
       selected_option: nil,
       candidates: :loading,
       selected_candidate: nil,
       save_error: nil
     )
     |> allow_upload(:poster,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 10_000_000
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      assign(socket, Map.take(assigns, [:id, :media_item, :current_scope, :metadata_config]))

    if socket.assigns.started? do
      {:ok, socket}
    else
      {:ok,
       socket
       |> assign(:started?, true)
       |> start_browse()
       |> start_candidates()}
    end
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    case Map.fetch(@tabs, tab) do
      {:ok, tab} -> {:noreply, assign(socket, tab: tab, save_error: nil)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("retry_browse", _params, socket), do: {:noreply, start_browse(socket)}

  def handle_event("select_option", %{"index" => index}, socket) do
    {:noreply,
     assign(socket, :selected_option, valid_index(index, socket.assigns.browse_results))}
  end

  def handle_event("select_candidate", %{"index" => index}, socket) do
    candidates = loaded(socket.assigns.candidates)
    {:noreply, assign(socket, :selected_candidate, valid_index(index, candidates))}
  end

  def handle_event("validate_upload", _params, socket),
    do: {:noreply, assign(socket, :save_error, nil)}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :poster, ref)}

  def handle_event("save", _params, socket) do
    authorized_write(socket, fn scope, item -> save(socket.assigns.tab, socket, scope, item) end)
  end

  def handle_event("reset", _params, socket) do
    authorized_write(socket, fn scope, item -> Posters.reset_poster(scope, item) end)
  end

  @impl true
  def handle_async(:browse, {:ok, {:ok, results}}, socket),
    do: {:noreply, assign(socket, browse: :ok, browse_results: results, selected_option: nil)}

  def handle_async(:browse, _failed, socket),
    do: {:noreply, assign(socket, browse: :error, browse_results: [], selected_option: nil)}

  def handle_async(:candidates, {:ok, candidates}, socket),
    do: {:noreply, assign(socket, :candidates, candidates)}

  def handle_async(:candidates, _failed, socket),
    do: {:noreply, assign(socket, :candidates, [])}

  defp start_browse(socket) do
    %{media_item: item, metadata_config: config} = socket.assigns

    socket
    |> assign(browse: :loading, browse_results: [], selected_option: nil)
    |> start_async(:browse, fn -> fetch_posters(config, item) end)
  end

  defp start_candidates(socket) do
    item = socket.assigns.media_item

    socket
    |> assign(:candidates, :loading)
    |> start_async(:candidates, fn -> Posters.list_library_poster_candidates(item) end)
  end

  # Results are {source label, %ImageData{}} pairs, best rated first and
  # unrated last. Only a fetch where every provider failed is an error.
  defp fetch_posters(config, item) do
    config = without_retries(config)
    media_type = if item.type == "tv_show", do: :tv_show, else: :movie

    results =
      for {source, ref} <- refs(item) do
        {source, Metadata.fetch_images_by_ref(config, ref, media_type: media_type)}
      end

    posters =
      for {source, {:ok, %{posters: posters}}} <- results,
          poster <- posters,
          is_binary(poster.file_path) and poster.file_path != "",
          do: {source, poster}

    if results != [] and Enum.all?(results, &match?({_, {:error, _}}, &1)) do
      {:error, :unavailable}
    else
      {:ok,
       posters
       |> Enum.uniq_by(fn {_source, poster} -> poster.file_path end)
       |> Enum.sort_by(fn {_source, poster} ->
         {is_nil(poster.vote_average), -(poster.vote_average || 0)}
       end)}
    end
  end

  # TVDB's images come from its series endpoint, so only a show asks it.
  defp refs(item) do
    tmdb = if item.tmdb_id, do: [{"TMDB", {:tmdb, item.tmdb_id}}], else: []

    tvdb =
      if item.tvdb_id && item.type == "tv_show",
        do: [{"TVDB", {:tvdb, item.tvdb_id}}],
        else: []

    tmdb ++ tvdb
  end

  # The picker has its own retry button, so a failing relay is reported at
  # once instead of after the HTTP client's backoff.
  defp without_retries(config) do
    Map.update(config, :options, %{max_retries: 0}, &Map.put(&1, :max_retries, 0))
  end

  defp authorized_write(socket, fun) do
    %{current_scope: scope, media_item: item} = socket.assigns

    if Authorization.can_update_media?(scope) do
      case fun.(scope, item) do
        {:ok, updated} ->
          send(self(), {:poster_changed, updated})
          {:noreply, assign(socket, :save_error, nil)}

        :noop ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :save_error, error_message(reason))}
      end
    else
      {:noreply, assign(socket, :save_error, error_message(:unauthorized))}
    end
  end

  defp save(:browse, socket, scope, item) do
    case selected(socket.assigns.browse_results, socket.assigns.selected_option) do
      {_source, poster} -> Posters.set_provider_poster(scope, item, poster.file_path)
      nil -> :noop
    end
  end

  defp save(:upload, socket, scope, item) do
    # consume_uploaded_entries/3 raises while an entry is still uploading.
    case uploaded_entries(socket, :poster) do
      {[_ | _], []} ->
        socket
        |> consume_uploaded_entries(:poster, fn %{path: path}, _entry ->
          {:ok, File.read!(path)}
        end)
        |> case do
          [binary | _] -> Posters.set_uploaded_poster(scope, item, binary)
          [] -> :noop
        end

      _ ->
        :noop
    end
  end

  defp save(:folder, socket, scope, item) do
    candidates = loaded(socket.assigns.candidates)

    case selected(candidates, socket.assigns.selected_candidate) do
      %Posters.Candidate{} = c ->
        Posters.set_poster_from_library_file(scope, item, c.library_path_id, c.relative_path)

      nil ->
        :noop
    end
  end

  defp selected(_list, nil), do: nil
  defp selected(list, index), do: Enum.at(list, index)

  defp valid_index(index, list) do
    case Integer.parse(to_string(index)) do
      {n, ""} when n >= 0 and n < length(list) -> n
      _ -> nil
    end
  end

  defp loaded(list) when is_list(list), do: list
  defp loaded(_), do: []

  defp can_save?(%{tab: :browse, selected_option: index}), do: index != nil
  defp can_save?(%{tab: :folder, selected_candidate: index}), do: index != nil

  defp can_save?(%{tab: :upload, uploads: uploads}) do
    entries = uploads.poster.entries
    entries != [] and Enum.all?(entries, &(&1.valid? and &1.done?))
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        current_path: Posters.effective_path(assigns.media_item),
        can_save: can_save?(assigns)
      )

    ~H"""
    <div
      id="poster-picker"
      class="modal modal-open"
      role="dialog"
      aria-labelledby="poster-picker-title"
      phx-window-keydown="close_poster_picker"
      phx-key="escape"
    >
      <div class="modal-box max-w-3xl">
        <h3 id="poster-picker-title" class="font-bold text-lg mb-3">{gettext("Change poster")}</h3>

        <div role="tablist" class="tabs tabs-box mb-4">
          <button
            :for={
              {tab, id, label} <- [
                {:browse, "poster-tab-browse", gettext("Browse")},
                {:upload, "poster-tab-upload", gettext("Upload")},
                {:folder, "poster-tab-folder", gettext("From folder")}
              ]
            }
            id={id}
            type="button"
            role="tab"
            aria-selected={to_string(@tab == tab)}
            class={["tab", @tab == tab && "tab-active"]}
            phx-click="tab"
            phx-value-tab={tab}
            phx-target={@myself}
          >
            {label}
          </button>
        </div>

        <div class="min-h-48 max-h-[60vh] overflow-y-auto">
          <%= case @tab do %>
            <% :browse -> %>
              <.browse_tab
                browse={@browse}
                results={@browse_results}
                selected={@selected_option}
                current_path={@current_path}
                myself={@myself}
              />
            <% :upload -> %>
              <.upload_tab uploads={@uploads} myself={@myself} />
            <% :folder -> %>
              <.folder_tab
                candidates={@candidates}
                selected={@selected_candidate}
                media_item={@media_item}
                myself={@myself}
              />
          <% end %>
        </div>

        <div :if={@save_error} id="poster-save-error" class="alert alert-error mt-4" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{@save_error}</span>
        </div>

        <div class="modal-action">
          <button
            :if={@media_item.poster_override}
            id="poster-reset"
            type="button"
            class="btn btn-ghost mr-auto"
            phx-click="reset"
            phx-target={@myself}
          >
            {gettext("Reset to default")}
          </button>
          <button type="button" class="btn btn-ghost" phx-click="close_poster_picker">
            {gettext("Cancel")}
          </button>
          <button
            id="poster-save"
            type="button"
            class="btn btn-primary"
            disabled={!@can_save}
            phx-click="save"
            phx-target={@myself}
          >
            {gettext("Save")}
          </button>
        </div>
      </div>
      <div id="poster-picker-backdrop" class="modal-backdrop" phx-click="close_poster_picker"></div>
    </div>
    """
  end
end
