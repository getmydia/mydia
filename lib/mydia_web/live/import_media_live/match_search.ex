defmodule MydiaWeb.ImportMediaLive.MatchSearch do
  @moduledoc """
  The "Change match" search behind `MydiaWeb.ImportMediaLive.Index`'s
  `@match_search` assign: opening it for a group, re-running it when the query
  or the TV provider changes, and folding the async result back in.

  The state is nil while the modal is closed, otherwise a map of `anchor_key`,
  `media_type`, `provider`, `library_provider`, `query`, `results`,
  `searching` and `error`. `provider` and `library_provider` are nil unless
  the search is a TV search; the provider toggle only renders when they are
  set.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  require Logger

  alias Mydia.Metadata
  alias Mydia.Metadata.TvProvider
  alias Mydia.Media.RemoteFilter

  @doc "Opens the search for `group`, prefilled with its suggested (or folder) title."
  def open(socket, group) do
    library_path = selected_library_path(socket)

    library_provider =
      if search_media_type(library_path, group.media_type) == :tv_show,
        do: TvProvider.for_library(library_path)

    state = %{
      anchor_key: group.anchor_key,
      media_type: group.media_type,
      provider: library_provider,
      library_provider: library_provider,
      query: group.suggested_title || group.display_title || "",
      results: [],
      searching: true,
      error: nil
    }

    socket |> assign(:match_search, state) |> run(state.query)
  end

  def change_query(%{assigns: %{match_search: nil}} = socket, _query), do: socket

  def change_query(socket, query) do
    state = socket.assigns.match_search

    socket
    |> assign(:match_search, %{state | query: query, searching: true, error: nil})
    |> run(query)
  end

  def change_provider(%{assigns: %{match_search: nil}} = socket, _value), do: socket

  def change_provider(socket, value) do
    case TvProvider.parse(value) do
      nil ->
        socket

      provider ->
        state = socket.assigns.match_search

        socket
        |> assign(:match_search, %{state | provider: provider, searching: true, error: nil})
        |> run(state.query)
    end
  end

  @doc "Applies a finished search unless a newer one, or another group's, has replaced it."
  def apply_result(socket, {token, anchor_key, result}) do
    if stale?(socket, token, anchor_key) do
      socket
    else
      assign(socket, :match_search, apply_search_result(socket.assigns.match_search, result))
    end
  end

  def crashed(socket, reason) do
    Logger.warning("Group match search crashed", reason: inspect(reason))

    case socket.assigns.match_search do
      nil -> socket
      state -> assign(socket, :match_search, %{state | searching: false, error: search_failed()})
    end
  end

  # Fires (or re-fires) the group match search asynchronously -- the page
  # this replaced ran two synchronous relay calls inline in a keystroke
  # handler and froze while they were in flight, which is exactly what
  # `start_async/3` exists to avoid. `phx-debounce="300"` on the modal's
  # input (see MatchSearchModal.match_search_modal/1) keeps every keystroke from
  # spawning its own request; the token here is what keeps a slow response
  # from an earlier one from clobbering a newer one that already landed.
  #
  # A blank query (the group's own display title, `PathAnchor`'s
  # "Loose files" fallback, or an emptied search box) is refused before
  # spawning a task at all: `Metadata.search/3`'s relay adapter treats an
  # empty query as invalid, so there is nothing useful to send. It still bumps
  # the token so a search already in flight cannot land on the cleared modal.
  defp run(socket, query) do
    token = socket.assigns.match_search_token + 1
    state = socket.assigns.match_search
    socket = assign(socket, :match_search_token, token)

    if String.trim(query) == "" do
      assign(socket, :match_search, %{state | results: [], searching: false})
    else
      media_type = search_media_type(selected_library_path(socket), state.media_type)
      opts = search_opts(media_type, state.provider)
      config = Metadata.default_relay_config()
      scope = socket.assigns.current_scope

      start_async(socket, :group_match_search, fn ->
        result =
          with {:ok, results} <- Metadata.search(config, query, opts) do
            {:ok, RemoteFilter.filter(results, scope)}
          end

        {token, state.anchor_key, result}
      end)
    end
  end

  defp search_opts(:tv_show, provider), do: [media_type: :tv_show, provider: provider]
  defp search_opts(media_type, _provider), do: [media_type: media_type]

  defp selected_library_path(socket) do
    Enum.find(socket.assigns.library_paths, &(&1.id == socket.assigns.selected_library_path_id))
  end

  # Scopes the search to the library's own media type where one is knowable,
  # per the design note this feature shipped against: a series library
  # should never offer movie results. A `:mixed` library has no single type
  # to scope by, so this falls back to the group's own `media_type` (already
  # known from its rollup) when the group has one, and otherwise leaves the
  # search unscoped -- `Metadata.search/3` defaults an unscoped query to a
  # movie search.
  defp search_media_type(%{type: :movies}, _hint), do: :movie
  defp search_media_type(%{type: :series}, _hint), do: :tv_show
  defp search_media_type(%{type: :mixed}, "tv_show"), do: :tv_show
  defp search_media_type(%{type: :mixed}, "movie"), do: :movie
  defp search_media_type(_library_path, _hint), do: nil

  defp stale?(socket, token, anchor_key) do
    case socket.assigns.match_search do
      nil -> true
      %{anchor_key: ^anchor_key} -> socket.assigns.match_search_token != token
      _different_group -> true
    end
  end

  defp apply_search_result(state, {:ok, results}) do
    %{state | results: results, searching: false, error: nil}
  end

  defp apply_search_result(state, {:error, reason}) do
    Logger.warning("Group match search failed", reason: inspect(reason))
    %{state | results: [], searching: false, error: search_failed()}
  end

  defp search_failed, do: "Search failed. Try again."
end
