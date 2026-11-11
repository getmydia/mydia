defmodule MydiaWeb.DiscoverLive.Ignores do
  @moduledoc """
  Discover's per-user ignore list (#1379).

  Ignored titles are hidden from browsing (the category grid and the regional
  rows) unless the user turns on "Show ignored". Search, the recommendations
  rail and person titles never hide them, so a deliberate search can always
  reach a title and bring it back.

  Keys are `{media_type, ref}`: TMDB numbers movies and TV separately, so the
  ref alone would let a movie ignore hide an unrelated show.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Ref
  alias MydiaWeb.Live.Helpers.DetailModal

  @doc "Sets `:ignored_keys`, `:show_ignored` and `:ignore_toast`."
  def assign_initial(socket) do
    {keys, show_ignored} =
      case socket.assigns[:current_user] do
        nil ->
          {MapSet.new(), false}

        user ->
          pref = Accounts.get_user_preference!(user)
          {Accounts.ignored_discover_keys(user), UserPreference.discover_show_ignored(pref)}
      end

    socket
    |> assign(:ignored_keys, keys)
    |> assign(:show_ignored, show_ignored)
    |> assign(:ignore_toast, nil)
  end

  @doc """
  The ignore key for a grid item. Falls back to the page's media type the same
  way the grid template does, since a curated page's items may not carry one.
  """
  def ignored_key(item, fallback_media_type) do
    {item.media_type || fallback_media_type, Ref.from_search_result(item)}
  end

  # The readers below tolerate assigns that never went through
  # assign_initial/1 (hand-built sockets in the auto-advance tests): no keys
  # means nothing is ignored.
  defp keys(assigns), do: Map.get(assigns, :ignored_keys) || MapSet.new()
  defp showing?(assigns), do: Map.get(assigns, :show_ignored, false)

  @doc "Whether this item is on the user's ignore list."
  def ignored?(assigns, item) do
    keys = keys(assigns)

    MapSet.size(keys) > 0 and
      MapSet.member?(keys, ignored_key(item, Map.get(assigns, :media_type)))
  end

  @doc """
  Whether browsing drops this item: owned while "Hide in library" is on, or
  ignored while "Show ignored" is off. The grid and the regional rows share it
  so the two can never disagree.
  """
  def hidden?(assigns, item) do
    (Map.get(assigns, :hide_owned, false) and item.in_library) or
      (not showing?(assigns) and ignored?(assigns, item))
  end

  @toast_ms 8_000

  @doc """
  Handles `ignore_title` and `unignore_title`. Returns the socket unchanged for
  a forged ref or media type, or when there is no user. The caller recomputes
  the visible items and auto-advances afterwards.
  """
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

  defp apply_event("ignore_title", socket, user, {media_type, ref} = key) do
    case Accounts.ignore_discover_title(user, ref, media_type) do
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
    :ok = Accounts.unignore_discover_title(user, ref, media_type)

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

  defp find_title(assigns, key) do
    rows = assigns |> Map.get(:regional_rows, %{}) |> Map.values() |> Enum.flat_map(& &1.items)

    [assigns[:selected_item] | Map.get(assigns, :items, []) ++ rows]
    |> Enum.find(&(&1 != nil and ignored_key(&1, assigns[:media_type]) == key))
    |> case do
      nil -> gettext("title")
      item -> item.title
    end
  end

  defp parse_media_type("movie"), do: {:ok, :movie}
  defp parse_media_type("tv_show"), do: {:ok, :tv_show}
  defp parse_media_type(_), do: :error

  @doc "Whether ignored titles are currently being dropped from browsing."
  def hiding_ignored?(assigns) do
    not showing?(assigns) and MapSet.size(keys(assigns)) > 0
  end
end
