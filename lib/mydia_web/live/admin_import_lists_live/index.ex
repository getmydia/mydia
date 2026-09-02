defmodule MydiaWeb.AdminImportListsLive.Index do
  @moduledoc """
  LiveView for managing import lists.

  Import lists allow users to automatically sync media from external sources like
  TMDB trending/popular lists.
  """
  use MydiaWeb, :live_view

  alias Mydia.ImportLists
  alias Mydia.ImportLists.ImportList
  alias Mydia.Settings
  alias Mydia.Collections
  alias Mydia.Jobs.ImportListSync

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if Mydia.ImportLists.FeatureFlags.enabled?() do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Mydia.PubSub, "import_lists")
      end

      {:ok,
       socket
       |> assign(:page_title, "Import Lists")
       |> assign(:show_list_modal, false)
       |> assign(:show_items_modal, false)
       |> assign(:show_preset_confirm_modal, false)
       |> assign(:pending_preset_id, nil)
       |> assign(:list_mode, nil)
       |> assign(:selected_list, nil)
       |> assign(:form, nil)
       |> assign(:items, [])
       |> assign(:items_filter, "all")
       |> assign(:syncing_list_id, nil)
       |> load_data()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Import Lists is currently disabled")
       |> redirect(to: ~p"/admin/dashboard")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  ## PubSub Handlers

  @impl true
  def handle_info({:import_list_sync_complete, import_list_id, result}, socket) do
    socket =
      case result do
        {:ok, stats} ->
          socket
          |> put_flash(:info, "Sync completed: #{stats.new} new, #{stats.total} total items")
          |> assign(:syncing_list_id, nil)
          |> load_data()

        {:error, reason} ->
          socket
          |> put_flash(:error, "Sync failed: #{inspect(reason)}")
          |> assign(:syncing_list_id, nil)
          |> load_data()
      end

    # If we're viewing items for this list, reload them
    socket =
      if socket.assigns.selected_list && socket.assigns.selected_list.id == import_list_id do
        load_list_items(socket, socket.assigns.selected_list, socket.assigns.items_filter)
      else
        socket
      end

    {:noreply, socket}
  end

  ## Data Loading

  defp load_data(socket) do
    import_lists =
      ImportLists.list_import_lists(
        preload: [:quality_profile, :library_path, :target_collection]
      )

    presets = ImportLists.available_preset_lists()
    quality_profiles = Settings.list_quality_profiles()
    library_paths = Settings.list_library_paths()

    # Load manual collections for target collection selector
    # Use the current user from the socket
    manual_collections =
      case socket.assigns[:current_scope] do
        %{user: user} ->
          Collections.list_collections(user, type: "manual")

        _ ->
          []
      end

    # Build map of configured preset IDs
    configured_presets =
      import_lists
      |> Enum.map(fn list -> {list.type, list.media_type} end)
      |> MapSet.new()

    socket
    |> assign(:import_lists, import_lists)
    |> assign(:presets, presets)
    |> assign(:configured_presets, configured_presets)
    |> assign(:quality_profiles, quality_profiles)
    |> assign(:library_paths, library_paths)
    |> assign(:manual_collections, manual_collections)
  end

  defp load_list_items(socket, import_list, filter) do
    opts =
      case filter do
        "all" -> []
        status -> [status: status]
      end

    items = ImportLists.list_import_list_items(import_list, opts)

    socket
    |> assign(:items, items)
    |> assign(:items_filter, filter)
  end

  ## Event Handlers - Presets

  @impl true
  def handle_event("enable_preset", %{"preset-id" => preset_id}, socket) do
    # Show confirmation modal asking about auto-add preference
    {:noreply,
     socket
     |> assign(:show_preset_confirm_modal, true)
     |> assign(:pending_preset_id, preset_id)}
  end

  @impl true
  def handle_event("confirm_enable_preset", %{"auto-add" => auto_add_str}, socket) do
    preset_id = socket.assigns.pending_preset_id
    preset_atom = String.to_existing_atom(preset_id)
    auto_add = auto_add_str == "true"

    case ImportLists.create_from_preset(preset_atom, auto_add: auto_add) do
      {:ok, import_list} ->
        # Trigger initial sync
        {:ok, _} = ImportListSync.enqueue(import_list.id)

        message =
          if auto_add do
            "#{import_list.name} enabled with auto-add and syncing"
          else
            "#{import_list.name} enabled and syncing (you'll review items before adding)"
          end

        {:noreply,
         socket
         |> assign(:show_preset_confirm_modal, false)
         |> assign(:pending_preset_id, nil)
         |> put_flash(:info, message)
         |> load_data()}

      {:error, :preset_not_found} ->
        {:noreply,
         socket
         |> assign(:show_preset_confirm_modal, false)
         |> assign(:pending_preset_id, nil)
         |> put_flash(:error, "Preset not found")}

      {:error, changeset} ->
        error_msg = format_changeset_errors(changeset)

        {:noreply,
         socket
         |> assign(:show_preset_confirm_modal, false)
         |> assign(:pending_preset_id, nil)
         |> put_flash(:error, "Failed to enable: #{error_msg}")}
    end
  end

  @impl true
  def handle_event("close_preset_confirm_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_preset_confirm_modal, false)
     |> assign(:pending_preset_id, nil)}
  end

  ## Event Handlers - List CRUD

  @impl true
  def handle_event("new_list", _params, socket) do
    changeset = ImportLists.change_import_list(%ImportList{})

    {:noreply,
     socket
     |> assign(:show_list_modal, true)
     |> assign(:list_mode, :new)
     |> assign(:selected_list, nil)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("edit_list", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id, preload: [:quality_profile, :library_path])
    changeset = ImportLists.change_import_list(import_list)

    {:noreply,
     socket
     |> assign(:show_list_modal, true)
     |> assign(:list_mode, :edit)
     |> assign(:selected_list, import_list)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate_list", %{"import_list" => params}, socket) do
    import_list = socket.assigns.selected_list || %ImportList{}

    changeset =
      import_list
      |> ImportLists.change_import_list(coerce_media_type(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_list", %{"import_list" => params}, socket) do
    case socket.assigns.list_mode do
      :new ->
        case ImportLists.create_import_list(params) do
          {:ok, import_list} ->
            {:noreply,
             socket
             |> put_flash(:info, "Import list created")
             |> assign(:show_list_modal, false)
             |> load_data()
             |> then(fn s ->
               # Trigger initial sync
               ImportListSync.enqueue(import_list.id)
               s
             end)}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      :edit ->
        case ImportLists.update_import_list(socket.assigns.selected_list, params) do
          {:ok, _import_list} ->
            {:noreply,
             socket
             |> put_flash(:info, "Import list updated")
             |> assign(:show_list_modal, false)
             |> load_data()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("close_list_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_list_modal, false)
     |> assign(:selected_list, nil)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_event("toggle_list", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id)

    case ImportLists.toggle_import_list(import_list) do
      {:ok, updated_list} ->
        status = if updated_list.enabled, do: "enabled", else: "disabled"

        {:noreply,
         socket
         |> put_flash(:info, "#{import_list.name} #{status}")
         |> load_data()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle list")}
    end
  end

  @impl true
  def handle_event("delete_list", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id)

    case ImportLists.delete_import_list(import_list) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{import_list.name} deleted")
         |> load_data()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete list")}
    end
  end

  ## Event Handlers - Sync

  @impl true
  def handle_event("sync_list", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id)

    case ImportListSync.enqueue(import_list.id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:syncing_list_id, id)
         |> put_flash(:info, "Sync started for #{import_list.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start sync: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("sync_all", _params, socket) do
    enabled_lists = Enum.filter(socket.assigns.import_lists, & &1.enabled)

    for list <- enabled_lists do
      ImportListSync.enqueue(list.id)
    end

    {:noreply, put_flash(socket, :info, "Sync started for #{length(enabled_lists)} lists")}
  end

  ## Event Handlers - Items

  @impl true
  def handle_event("view_items", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id)

    {:noreply,
     socket
     |> assign(:show_items_modal, true)
     |> assign(:selected_list, import_list)
     |> load_list_items(import_list, "all")}
  end

  @impl true
  def handle_event("filter_items", %{"status" => status}, socket) do
    {:noreply, load_list_items(socket, socket.assigns.selected_list, status)}
  end

  @impl true
  def handle_event("close_items_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_items_modal, false)
     |> assign(:selected_list, nil)
     |> assign(:items, [])}
  end

  @impl true
  def handle_event("reset_item", %{"id" => id}, socket) do
    item = ImportLists.get_import_list_item!(id)

    case ImportLists.reset_item(item) do
      {:ok, _} ->
        {:noreply,
         load_list_items(socket, socket.assigns.selected_list, socket.assigns.items_filter)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reset item")}
    end
  end

  @impl true
  def handle_event("add_item_to_library", %{"id" => id}, socket) do
    item = ImportLists.get_import_list_item!(id)
    import_list = socket.assigns.selected_list

    socket =
      case ImportLists.add_item_to_library(item, import_list) do
        {:ok, media_item} ->
          put_flash(socket, :info, "#{media_item.title} added to library")

        {:error, reason} when is_binary(reason) ->
          put_flash(socket, :error, "Failed to add: #{reason}")

        {:error, _reason} ->
          put_flash(socket, :error, "Failed to add item to library")
      end

    {:noreply,
     socket
     |> load_list_items(import_list, socket.assigns.items_filter)
     |> load_data()}
  end

  @impl true
  def handle_event("add_all_pending", _params, socket) do
    import_list = socket.assigns.selected_list
    stats = ImportLists.add_all_pending_to_library(import_list)

    message =
      cond do
        stats.added > 0 and stats.skipped > 0 ->
          "Added #{stats.added} items, #{stats.skipped} already in library"

        stats.added > 0 ->
          "Added #{stats.added} items to library"

        stats.skipped > 0 ->
          "#{stats.skipped} items already in library"

        stats.failed > 0 ->
          "Failed to add #{stats.failed} items"

        true ->
          "No pending items to add"
      end

    socket =
      if stats.failed > 0 and stats.added == 0 do
        put_flash(socket, :error, message)
      else
        put_flash(socket, :info, message)
      end

    {:noreply,
     socket
     |> load_list_items(import_list, socket.assigns.items_filter)
     |> load_data()}
  end

  @impl true
  def handle_event("add_pending_from_table", %{"id" => id}, socket) do
    import_list = ImportLists.get_import_list!(id)
    stats = ImportLists.add_all_pending_to_library(import_list)

    message =
      cond do
        stats.added > 0 and stats.skipped > 0 ->
          "Added #{stats.added} items, #{stats.skipped} already in library"

        stats.added > 0 ->
          "Added #{stats.added} items to library"

        stats.skipped > 0 ->
          "#{stats.skipped} items already in library"

        stats.failed > 0 ->
          "Failed to add #{stats.failed} items"

        true ->
          "No pending items to add"
      end

    socket =
      if stats.failed > 0 and stats.added == 0 do
        put_flash(socket, :error, message)
      else
        put_flash(socket, :info, message)
      end

    {:noreply, load_data(socket)}
  end

  ## Helpers

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp format_changeset_errors(_), do: "Unknown error"

  ## Helper Functions for Template

  def preset_configured?(configured_presets, type, media_type) do
    MapSet.member?(configured_presets, {type, media_type})
  end

  def format_last_synced(nil), do: "Never"

  def format_last_synced(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86400 -> "#{div(diff, 3600)} hours ago"
      true -> "#{div(diff, 86400)} days ago"
    end
  end

  def item_count_badge(import_list) do
    total = ImportLists.count_import_list_items(import_list)
    pending = ImportLists.count_import_list_items(import_list, "pending")

    # Don't show pending count for auto-add lists since they'll be added automatically
    if pending > 0 and not import_list.auto_add do
      "#{pending} pending / #{total} total"
    else
      "#{total} items"
    end
  end

  def pending_count(import_list) do
    ImportLists.count_import_list_items(import_list, "pending")
  end

  def pending_items_in_list?(items) do
    Enum.any?(items, fn item -> display_status(item) == "pending" end)
  end

  def group_items_by_status(items) do
    # Sort items by effective status: pending first, then added, then skipped, then failed
    status_order = %{"pending" => 0, "added" => 1, "skipped" => 2, "failed" => 3}

    Enum.sort_by(items, fn item ->
      effective_status = display_status(item)
      {Map.get(status_order, effective_status, 4), item.discovered_at}
    end)
  end

  def status_explanation(status) do
    case status do
      "pending" -> "Waiting to be added to library"
      "added" -> "Successfully added to your library"
      "skipped" -> "Skipped (already in library or manually skipped)"
      "failed" -> "Failed to add (click to retry)"
      _ -> ""
    end
  end

  def get_preset_name(preset_id) when is_binary(preset_id) do
    presets = ImportLists.available_preset_lists()
    preset_atom = String.to_existing_atom(preset_id)
    preset = Enum.find(presets, fn p -> p.id == preset_atom end)

    if preset do
      preset.name
    else
      preset_id
    end
  end

  # Keeps the media type in step with the chosen list source. Several TMDB
  # sources only ever publish one media type, so once the operator picks one
  # of those the incompatible option is no longer offered by the select. Without
  # this the form would keep submitting a value the operator can no longer see.
  defp coerce_media_type(%{"type" => type, "media_type" => media_type} = params)
       when is_binary(type) and is_binary(media_type) do
    case ImportList.compatible_media_types(type) do
      [only] when only != media_type -> Map.put(params, "media_type", only)
      _ -> params
    end
  end

  defp coerce_media_type(params), do: params

  @doc """
  Returns the media type select options a list source actually supports.

  Movie-only and TV-only TMDB sources offer a single option so an operator
  cannot build a list whose source and media type disagree.
  """
  def media_type_options(type) when is_binary(type) and type != "" do
    type
    |> ImportList.compatible_media_types()
    |> Enum.map(&{media_type_label(&1), &1})
  end

  # No source picked yet, so nothing narrows the choice.
  def media_type_options(_type) do
    Enum.map(ImportList.valid_media_types(), &{media_type_label(&1), &1})
  end

  defp media_type_label("movie"), do: "Movies"
  defp media_type_label("tv_show"), do: "TV Shows"
  defp media_type_label(other), do: other

  def media_type_icon("movie"), do: "hero-film"
  def media_type_icon("tv_show"), do: "hero-tv"
  def media_type_icon(_), do: "hero-queue-list"

  def status_badge_class("pending"), do: "badge-warning"
  def status_badge_class("added"), do: "badge-success"
  def status_badge_class("skipped"), do: "badge-ghost"
  def status_badge_class("failed"), do: "badge-error"
  def status_badge_class(_), do: "badge-ghost"

  @doc """
  Returns the display status for an item, considering whether it's actually in the library.

  If an item was marked as "added" but the media_item no longer exists (was removed),
  we show it as "pending" so the user can re-add it.
  """
  def display_status(item) do
    # If status is "added" but not in library, treat as pending
    if item.status == "added" and not item.in_library do
      "pending"
    else
      # Otherwise use the stored status
      item.status
    end
  end
end
