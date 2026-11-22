defmodule MydiaWeb.MediaLive.Show.PosterPicker do
  @moduledoc """
  The poster picker on the media detail page: choose a provider poster
  (Browse), upload an image (Upload) or use an image file from the item's
  folder (From folder), or go back to the provider's default (Reset).

  The parent mounts it only while it is open and closes it with the
  `close_poster_picker` event. After a successful write it sends
  `{:poster_changed, item}` to the parent, which reloads the item.

  Selections are indexes into lists this component holds on the server, so
  the client never names a poster path or a file. Every write checks
  `Mydia.Accounts.Authorization.can_update_media?/1` again.
  """

  use MydiaWeb, :live_component

  alias Mydia.Accounts.Authorization
  alias Mydia.Media.Posters
  alias Mydia.Metadata
  alias Mydia.Metadata.ImageUrl
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

  defp error_message(:unsupported_format),
    do: gettext("That file is not a JPEG, PNG or WebP image.")

  defp error_message(:too_large), do: gettext("That image is larger than 10 MB.")
  defp error_message(:not_found), do: gettext("That file is no longer in the item's folder.")
  defp error_message(:invalid_poster), do: gettext("That poster cannot be used.")

  defp error_message(reason) when reason in [:unauthorized, :restricted],
    do: gettext("You do not have permission to change this poster.")

  defp error_message(_), do: gettext("The poster could not be saved.")

  defp upload_error_message(:too_large), do: error_message(:too_large)
  defp upload_error_message(:not_accepted), do: error_message(:unsupported_format)
  defp upload_error_message(:too_many_files), do: gettext("Choose one image.")
  defp upload_error_message(_), do: error_message(:other)

  defp can_save?(%{tab: :browse, selected_option: index}), do: index != nil
  defp can_save?(%{tab: :folder, selected_candidate: index}), do: index != nil

  defp can_save?(%{tab: :upload, uploads: uploads}) do
    entries = uploads.poster.entries
    entries != [] and Enum.all?(entries, &(&1.valid? and &1.done?))
  end

  defp admin?(%{user: user}), do: Authorization.has_role?(user, :admin)
  defp admin?(_), do: false

  defp candidate_src(item, %Posters.Candidate{} = c) do
    ~p"/admin/media/#{item.id}/poster-candidates/#{c.library_path_id}/#{Path.split(c.relative_path)}"
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
                show_thumbnails={admin?(@current_scope)}
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
    </div>
    """
  end

  attr :browse, :atom, required: true
  attr :results, :list, required: true
  attr :selected, :integer, default: nil
  attr :current_path, :string, default: nil
  attr :myself, :any, required: true

  defp browse_tab(assigns) do
    ~H"""
    <%= case @browse do %>
      <% :loading -> %>
        <div class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% :error -> %>
        <div id="poster-browse-error" class="alert alert-error" role="alert">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{gettext("Could not load posters from the metadata provider.")}</span>
          <button type="button" class="btn btn-sm" phx-click="retry_browse" phx-target={@myself}>
            {gettext("Retry")}
          </button>
        </div>
      <% :ok -> %>
        <p :if={@results == []} class="text-sm opacity-70 py-8 text-center">
          {gettext("The metadata provider has no posters for this title.")}
        </p>
        <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-3">
          <button
            :for={{{source, poster}, index} <- Enum.with_index(@results)}
            id={"poster-option-#{index}"}
            type="button"
            aria-pressed={to_string(@selected == index)}
            class={[
              "relative rounded-box overflow-hidden border-2 transition-colors",
              if(@selected == index,
                do: "border-primary",
                else: "border-transparent hover:border-base-content/30"
              )
            ]}
            phx-click="select_option"
            phx-value-index={index}
            phx-target={@myself}
          >
            <img
              src={ImageUrl.poster_url(poster.file_path, "w185")}
              alt=""
              loading="lazy"
              class="aspect-[2/3] w-full object-cover bg-base-300"
            />
            <span class="absolute bottom-1 left-1 flex gap-1">
              <span class="badge badge-xs badge-neutral">{source}</span>
              <span :if={poster.language} class="badge badge-xs badge-neutral">
                {poster.language}
              </span>
            </span>
            <span
              :if={poster.file_path == @current_path}
              class="badge badge-xs badge-primary absolute top-1 right-1"
            >
              {gettext("Current")}
            </span>
          </button>
        </div>
    <% end %>
    """
  end

  attr :uploads, :map, required: true
  attr :myself, :any, required: true

  defp upload_tab(assigns) do
    ~H"""
    <form
      id="poster-upload-form"
      phx-change="validate_upload"
      phx-submit="save"
      phx-target={@myself}
      class="flex flex-col gap-4"
    >
      <label class="flex flex-col gap-2">
        <span class="text-sm opacity-75">
          {gettext("JPEG, PNG or WebP, up to 10 MB.")}
        </span>
        <.live_file_input upload={@uploads.poster} class="file-input w-full" />
      </label>

      <div :for={entry <- @uploads.poster.entries} class="flex items-start gap-4">
        <.live_img_preview entry={entry} class="w-32 aspect-[2/3] object-cover rounded-box" />
        <div class="flex-1 min-w-0">
          <p class="text-sm truncate">{entry.client_name}</p>
          <p
            :for={err <- upload_errors(@uploads.poster, entry)}
            class="text-sm text-error"
          >
            {upload_error_message(err)}
          </p>
          <button
            type="button"
            class="btn btn-ghost btn-xs mt-2"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-target={@myself}
          >
            {gettext("Remove")}
          </button>
        </div>
      </div>

      <p :for={err <- upload_errors(@uploads.poster)} class="text-sm text-error">
        {upload_error_message(err)}
      </p>
    </form>
    """
  end

  attr :candidates, :any, required: true
  attr :selected, :integer, default: nil
  attr :media_item, :map, required: true
  attr :show_thumbnails, :boolean, required: true
  attr :myself, :any, required: true

  defp folder_tab(assigns) do
    ~H"""
    <%= cond do %>
      <% @candidates == :loading -> %>
        <div class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% @candidates == [] -> %>
        <p class="text-sm opacity-70 py-8 text-center">
          {gettext("No JPEG, PNG or WebP files sit next to this item's files.")}
        </p>
      <% true -> %>
        <div class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 gap-3">
          <button
            :for={{candidate, index} <- Enum.with_index(@candidates)}
            id={"poster-candidate-#{index}"}
            type="button"
            aria-pressed={to_string(@selected == index)}
            class={[
              "flex flex-col rounded-box overflow-hidden border-2 transition-colors text-left",
              if(@selected == index,
                do: "border-primary",
                else: "border-transparent hover:border-base-content/30"
              )
            ]}
            phx-click="select_candidate"
            phx-value-index={index}
            phx-target={@myself}
          >
            <img
              :if={@show_thumbnails}
              src={candidate_src(@media_item, candidate)}
              alt=""
              loading="lazy"
              class="aspect-[2/3] w-full object-cover bg-base-300"
            />
            <div
              :if={!@show_thumbnails}
              class="aspect-[2/3] w-full bg-base-300 flex items-center justify-center"
            >
              <.icon name="hero-photo" class="w-8 h-8 opacity-40" />
            </div>
            <span class="text-xs truncate px-1 py-0.5">{candidate.name}</span>
          </button>
        </div>
    <% end %>
    """
  end
end
