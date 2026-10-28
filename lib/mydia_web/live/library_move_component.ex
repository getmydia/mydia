defmodule MydiaWeb.Live.LibraryMoveComponent do
  @moduledoc """
  The "Move to library" dialog: moves one or more media items, with all of
  their files, into another library through `Mydia.Library.LibraryMove`.

  Used by the detail page (one item) and the library list's batch toolbar
  (the selection). Open it with `JS.push("open", target: "#<id>")`. Moving
  takes the same permission as deleting from disk.
  """

  use MydiaWeb, :live_component

  alias Mydia.Library.LibraryMove
  alias Mydia.Media
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.ComponentFlash

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open?: false, items: [], targets: [], selected_id: nil, preview: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     assign(socket, Map.take(assigns, [:id, :media_item_ids, :current_user, :current_scope]))}
  end

  @impl true
  def handle_event("open", _params, socket) do
    items =
      Media.list_media_items(socket.assigns.current_scope, ids: socket.assigns.media_item_ids)

    targets = targets_for(items)

    {:noreply,
     socket
     |> assign(open?: true, items: items, targets: targets)
     |> select_target(targets |> List.first() |> target_id())}
  end

  def handle_event("select", %{"target" => id}, socket),
    do: {:noreply, select_target(socket, id)}

  def handle_event("confirm", params, socket) do
    socket = select_target(socket, params["target"] || socket.assigns.selected_id)

    case Authorization.authorize_delete_media(socket) do
      :ok ->
        {:noreply, move(socket)}

      # The refusal flash lands on this component's socket; show it on the page.
      {:unauthorized, socket} ->
        ComponentFlash.put(:error, Phoenix.Flash.get(socket.assigns.flash, :error))
        {:noreply, assign(socket, :open?, false)}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open?, false)}

  # Every library holds an empty selection; offer none.
  defp targets_for([]), do: []

  # The library every file of every item already sits in is not a move.
  defp targets_for(items) do
    current =
      items
      |> Enum.flat_map(&LibraryMove.item_files(&1.id))
      |> Enum.map(& &1.library_path_id)
      |> Enum.uniq()

    targets = LibraryMove.compatible_targets(items)

    case current do
      [only] -> Enum.reject(targets, &(&1.id == only))
      _ -> targets
    end
  end

  defp target_id(nil), do: nil
  defp target_id(%LibraryPath{id: id}), do: to_string(id)

  defp selected_target(%{targets: targets, selected_id: id}),
    do: Enum.find(targets, &(target_id(&1) == id))

  defp select_target(socket, id) do
    socket = assign(socket, :selected_id, id && to_string(id))
    assign(socket, :preview, plan_preview(socket.assigns.items, selected_target(socket.assigns)))
  end

  defp plan_preview(_items, nil), do: nil
  defp plan_preview([item], target), do: LibraryMove.preview(item, target)

  # Many items: totals only, no example paths.
  defp plan_preview(items, target) do
    previews = Enum.map(items, &LibraryMove.preview(&1, target))
    sum = fn key -> previews |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

    %{
      files: sum.(:files),
      bytes: sum.(:bytes),
      hardlink: sum.(:hardlink),
      copy: sum.(:copy),
      examples: []
    }
  end

  defp move(socket) do
    case selected_target(socket.assigns) do
      nil ->
        :ok

      target ->
        report(enqueue(socket.assigns.items, target, socket.assigns.current_scope), target)
    end

    assign(socket, :open?, false)
  end

  defp enqueue([item], target, scope) do
    case LibraryMove.enqueue(item, target, scope) do
      {:ok, _job} -> {1, []}
      {:error, reason} -> {0, [{item, reason}]}
    end
  end

  defp enqueue(items, target, scope), do: LibraryMove.enqueue_many(items, target, scope)

  defp report({count, refusals}, target) do
    library = LibraryPath.display_name(target)

    if count > 0 do
      message =
        ngettext(
          "Moving %{count} item to %{library}",
          "Moving %{count} items to %{library}",
          count,
          library: library
        )

      ComponentFlash.put(:info, message)
    end

    if refusals != [], do: ComponentFlash.put(:error, refusal_message(refusals, library))
  end

  defp refusal_message(refusals, library) do
    refusals
    |> Enum.frequencies_by(fn {_item, reason} -> reason end)
    |> Enum.map_join(" ", fn {reason, n} -> refusal(reason, n, library) end)
  end

  defp refusal(:incompatible_library, n, library),
    do:
      ngettext(
        "%{count} item was not moved: %{library} is not a library for this kind of media.",
        "%{count} items were not moved: %{library} is not a library for this kind of media.",
        n,
        library: library
      )

  defp refusal(:disabled_library, n, _library),
    do:
      ngettext(
        "%{count} item was not moved: that library is disabled.",
        "%{count} items were not moved: that library is disabled.",
        n
      )

  defp refusal(:already_there, n, _library),
    do:
      ngettext(
        "%{count} item is already in that library.",
        "%{count} items are already in that library.",
        n
      )

  defp refusal(:import_in_progress, n, _library),
    do:
      ngettext(
        "%{count} item was not moved: an import is still running.",
        "%{count} items were not moved: an import is still running.",
        n
      )

  defp refusal(:move_in_progress, n, _library),
    do:
      ngettext(
        "%{count} item was not moved: a move is already running.",
        "%{count} items were not moved: a move is already running.",
        n
      )

  defp refusal(:restricted, n, _library),
    do:
      ngettext(
        "%{count} item was not moved: it is outside what your account is allowed to access.",
        "%{count} items were not moved: they are outside what your account is allowed to access.",
        n
      )

  defp refusal(_other, n, _library),
    do: ngettext("%{count} item could not be moved.", "%{count} items could not be moved.", n)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        form: to_form(%{"target" => assigns.selected_id}),
        labels: LibraryPath.display_names(assigns.targets)
      )

    ~H"""
    <div id={@id}>
      <.modal
        :if={@open?}
        id={"#{@id}-modal"}
        show={@open?}
        on_cancel={JS.push("close", target: @myself)}
      >
        <:title>{gettext("Move to library")}</:title>
        <%= if @targets == [] do %>
          <p id="library-move-empty" class="text-sm text-base-content/70">
            {gettext("No other library can hold this.")}
          </p>
        <% else %>
          <.form
            for={@form}
            id="library-move-form"
            phx-change="select"
            phx-submit="confirm"
            phx-target={@myself}
          >
            <.input
              type="select"
              field={@form[:target]}
              label={gettext("Library")}
              options={Enum.map(@targets, &{@labels[&1.id], &1.id})}
            />
          </.form>
          <.preview :if={@preview} preview={@preview} />
        <% end %>
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>
            {gettext("Cancel")}
          </button>
          <button
            id="library-move-confirm"
            type="submit"
            form="library-move-form"
            class="btn btn-primary"
            disabled={@targets == []}
          >
            {gettext("Move")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end

  attr :preview, :map, required: true

  defp preview(assigns) do
    ~H"""
    <div id="library-move-preview" class="mt-4 space-y-2 text-sm">
      <p>
        {ngettext("%{count} file, %{size}", "%{count} files, %{size}", @preview.files,
          size: MydiaWeb.Formatters.format_file_size(@preview.bytes)
        )}
      </p>
      <p class="text-base-content/70">
        {gettext("%{hardlinked} hardlinked, %{copied} copied",
          hardlinked: @preview.hardlink,
          copied: @preview.copy
        )}
      </p>
      <ul :if={@preview.examples != []} id="library-move-examples" class="space-y-1">
        <li :for={{from, to} <- @preview.examples} class="font-mono text-xs break-all">
          <span class="text-base-content/60">{from}</span>
          <.icon name="hero-arrow-right" class="w-3 h-3 mx-1" />
          <span>{to}</span>
        </li>
      </ul>
    </div>
    """
  end
end
