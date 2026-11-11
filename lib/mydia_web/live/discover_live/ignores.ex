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

  import Phoenix.Component, only: [assign: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata.Ref

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

  @doc "Whether ignored titles are currently being dropped from browsing."
  def hiding_ignored?(assigns) do
    not showing?(assigns) and MapSet.size(keys(assigns)) > 0
  end
end
