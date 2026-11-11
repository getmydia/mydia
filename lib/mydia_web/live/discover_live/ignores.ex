defmodule MydiaWeb.DiscoverLive.Ignores do
  @moduledoc """
  Discover's browse filters: "Hide in library" and the per-user ignore list
  (#1379).

  Ignored titles are hidden from browsing (the category grid and the regional
  rows) unless the user turns on "Show ignored". Search, the recommendations
  rail and person titles never hide them, so a deliberate search can always
  reach a title and bring it back.

  Keys are `{media_type, ref}`: TMDB numbers movies and TV separately, so the
  ref alone would let a movie ignore hide an unrelated show.

  Templates call the explicit-argument `ignored?/3` with `@ignored_keys` and
  `@media_type`, never a function of bare `assigns`: LiveView cannot track what
  such an expression depends on, so it would re-render every card on every
  unrelated change.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.{DiscoverIgnores, UserPreference}
  alias Mydia.Metadata.Ref
  alias MydiaWeb.Live.Helpers.DetailModal

  @toast_ms 8_000

  @doc "Sets `:hide_owned`, `:ignored_keys`, `:show_ignored` and `:ignore_toast`."
  def assign_initial(socket) do
    {hide_owned, keys, show_ignored} =
      case socket.assigns[:current_user] do
        nil ->
          {false, MapSet.new(), false}

        user ->
          pref = Accounts.get_user_preference!(user)

          {UserPreference.discover_hide_owned(pref), DiscoverIgnores.keys(user),
           UserPreference.discover_show_ignored(pref)}
      end

    socket
    |> assign(:hide_owned, hide_owned)
    |> assign(:ignored_keys, keys)
    |> assign(:show_ignored, show_ignored)
    |> assign(:ignore_toast, nil)
  end

  @doc """
  The items the grid shows. Browsing applies both filters; search applies only
  "Hide in library", since search is how a user finds an ignored title again.
  """
  def visible_items(assigns) do
    if Map.get(assigns, :search_mode, false) do
      if assigns.hide_owned, do: Enum.reject(assigns.items, & &1.in_library), else: assigns.items
    else
      Enum.reject(assigns.items, &hidden?(assigns, &1))
    end
  end

  defdelegate ignored_key(item, fallback_media_type), to: DiscoverIgnores, as: :key_for
  defdelegate ignored?(keys, fallback_media_type, item), to: DiscoverIgnores

  @doc """
  Whether browsing drops this item: owned while "Hide in library" is on, or
  ignored while "Show ignored" is off. The grid and the regional rows share it
  so the two can never disagree. `filters` needs `:hide_owned`, `:show_ignored`,
  `:ignored_keys` and `:media_type`; the first three default to "off" so a
  socket built without assign_initial/1 filters nothing.
  """
  def hidden?(filters, item) do
    (Map.get(filters, :hide_owned, false) and item.in_library) or
      (not Map.get(filters, :show_ignored, false) and
         ignored?(keys(filters), Map.get(filters, :media_type), item))
  end

  @doc "Whether ignored titles are currently being dropped from browsing."
  def hiding_ignored?(assigns) do
    not Map.get(assigns, :show_ignored, false) and MapSet.size(keys(assigns)) > 0
  end

  defp keys(assigns), do: Map.get(assigns, :ignored_keys) || MapSet.new()

  @doc """
  Handles the browse-filter events: `toggle_hide_owned`, `toggle_show_ignored`,
  `ignore_title` and `unignore_title`. A forged ref or media type, or a missing
  user, leaves the socket unchanged. The caller recomputes the visible items
  and auto-advances afterwards.
  """
  def handle_event("toggle_hide_owned", _params, socket),
    do: {:noreply, toggle(socket, :hide_owned, "discover_hide_owned")}

  def handle_event("toggle_show_ignored", _params, socket),
    do: {:noreply, toggle(socket, :show_ignored, "discover_show_ignored")}

  def handle_event(event, %{"ref" => raw_ref, "media_type" => raw_type}, socket)
      when event in ["ignore_title", "unignore_title"] do
    with user when not is_nil(user) <- socket.assigns[:current_user],
         {:ok, ref} <- Ref.parse(raw_ref),
         {:ok, media_type} <- parse_media_type(raw_type) do
      {:noreply, apply_event(event, socket, user, {media_type, ref})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A rejected write leaves the toggle where it was rather than flipping the
  # grid for a preference that will be gone on the next mount.
  defp toggle(socket, assign_key, pref_key) do
    value = not socket.assigns[assign_key]

    case persist_preference(socket, pref_key, value) do
      :ok -> assign(socket, assign_key, value)
      :error -> put_flash(socket, :error, gettext("Could not save that filter preference"))
    end
  end

  defp persist_preference(socket, key, value) do
    case socket.assigns[:current_user] do
      nil ->
        :ok

      user ->
        preference = Accounts.get_user_preference!(user)

        case Accounts.update_preference(preference, %{"preferences" => %{key => value}}) do
          {:ok, _} -> :ok
          {:error, _changeset} -> :error
        end
    end
  end

  defp apply_event("ignore_title", socket, user, {media_type, ref} = key) do
    case DiscoverIgnores.ignore(user, ref, media_type) do
      :ok ->
        Process.send_after(self(), {:clear_ignore_toast, key}, @toast_ms)

        socket
        |> assign(:ignored_keys, MapSet.put(keys(socket.assigns), key))
        |> assign(:ignore_toast, %{key: key, title: find_title(socket.assigns, key)})
        |> close_modal_for(key)

      {:error, _changeset} ->
        put_flash(socket, :error, gettext("Could not ignore that title"))
    end
  end

  defp apply_event("unignore_title", socket, user, {media_type, ref} = key) do
    :ok = DiscoverIgnores.unignore(user, ref, media_type)

    socket
    |> assign(:ignored_keys, MapSet.delete(keys(socket.assigns), key))
    |> clear_toast(key)
  end

  @doc "Clears the toast, but only if it still names `key`, so a stale timer cannot clear a newer toast."
  def clear_toast(socket, key) do
    case socket.assigns[:ignore_toast] do
      %{key: ^key} -> assign(socket, :ignore_toast, nil)
      _ -> socket
    end
  end

  # Ignoring from the detail modal closes it: the title is gone from the grid
  # behind it, and the modal has nothing more to offer.
  defp close_modal_for(socket, key) do
    case socket.assigns[:selected_item] do
      nil ->
        socket

      item ->
        if ignored_key(item, socket.assigns[:media_type]) == key,
          do: DetailModal.close(socket),
          else: socket
    end
  end

  # nil when the title is on no list this page holds; the toast then says
  # "Title ignored" as a whole sentence rather than splicing in a fragment.
  defp find_title(assigns, key) do
    rows = assigns |> Map.get(:regional_rows, %{}) |> Map.values() |> Enum.flat_map(& &1.items)

    [assigns[:selected_item] | Map.get(assigns, :items, []) ++ rows]
    |> Enum.find(&(&1 != nil and ignored_key(&1, assigns[:media_type]) == key))
    |> case do
      nil -> nil
      item -> item.title
    end
  end

  defp parse_media_type("movie"), do: {:ok, :movie}
  defp parse_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_media_type(_), do: :error
end
