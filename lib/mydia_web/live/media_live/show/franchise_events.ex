defmodule MydiaWeb.MediaLive.Show.FranchiseEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, put_flash: 3, connected?: 1]

  alias Mydia.Accounts.Authorization, as: AccountsAuthorization
  alias Mydia.Media.FranchiseEntry
  alias Mydia.Media.Franchises
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  require Logger

  @doc """
  Starts the franchise lookup for movies on the connected mount.

  A no-op on the dead render (the lookup makes an HTTP call and the dead render
  must not pay for it) and for anything that is not a movie with a TMDB id.
  """
  def maybe_load(socket) do
    media_item = socket.assigns.media_item
    config = socket.assigns.metadata_config

    if connected?(socket) && media_item.type == "movie" && is_integer(media_item.tmdb_id) do
      start_async(socket, :load_franchise, fn ->
        Franchises.for_media_item(media_item, config)
      end)
    else
      socket
    end
  end

  def handle_load_result({:ok, {:ok, franchise}}, socket) do
    franchise = enrich_with_request_status(franchise, socket.assigns.current_user)
    {:noreply, assign(socket, :franchise, franchise)}
  end

  def handle_load_result({:ok, :none}, socket) do
    {:noreply, socket}
  end

  def handle_load_result({:exit, reason}, socket) do
    Logger.warning("Franchise lookup crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  # Defensive: an unmatched shape would otherwise raise in the LiveView process,
  # and the client would reconnect, re-mount and crash again, taking the whole
  # movie page down for a section that is meant to be silently absent when the
  # lookup does not work out.
  def handle_load_result(other, socket) do
    Logger.warning("Franchise lookup returned an unexpected result: #{inspect(other)}")
    {:noreply, socket}
  end

  @doc """
  Adds a missing franchise member, inheriting the viewed movie's quality profile
  and monitored flag.

  Adds are keyed per TMDB id so several can be in flight at once: a franchise is
  usually missing more than one entry, and `start_async/3` overwrites rather than
  cancels a task under an existing key, which would silently drop the first
  result.
  """
  def add_franchise_movie(%{"tmdb_id" => tmdb_id} = params, socket) do
    with :ok <- Authorization.authorize_create_media(socket),
         {:ok, opts} <- MediaAddHelpers.library_path_opts(params["library_path_id"], :movie) do
      start_add(tmdb_id, opts, socket)
    else
      {:unauthorized, socket} ->
        {:noreply, socket}

      {:error, :unknown_library} ->
        {:noreply,
         put_flash(socket, :error, "That library is no longer available. Nothing was added.")}
    end
  end

  defp start_add(tmdb_id, opts, socket) do
    case Integer.parse(tmdb_id) do
      {tmdb_id, ""} -> dispatch_add(tmdb_id, opts, socket)
      _ -> {:noreply, socket}
    end
  end

  # An impatient double-click sends the event twice. The second add would hit the
  # tmdb_id unique index and flash a failure for a row the first add just
  # created, so a repeat for an id already in flight is dropped.
  #
  # The in-flight set stays keyed on tmdb_id alone and `opts` rides beside it.
  defp dispatch_add(tmdb_id, opts, socket) do
    if MapSet.member?(socket.assigns.adding_franchise_tmdb_ids, tmdb_id) do
      {:noreply, socket}
    else
      media_item = socket.assigns.media_item
      config = socket.assigns.metadata_config

      socket =
        socket
        |> mark_in_flight(tmdb_id)
        |> start_async({:add_franchise_movie, tmdb_id}, fn ->
          perform_add(media_item, tmdb_id, config, opts)
        end)

      {:noreply, socket}
    end
  end

  @doc """
  Performs the add. Public so it can be exercised directly in tests without a
  live process.
  """
  def perform_add(media_item, tmdb_id, config, opts \\ []) do
    MediaAddHelpers.handle_add_media_to_library(
      to_string(tmdb_id),
      :movie,
      %{},
      config,
      Keyword.merge(
        [monitored: media_item.monitored, quality_profile_id: media_item.quality_profile_id],
        opts
      )
    )
    |> case do
      {:ok, added, _status_map} -> {:ok, added}
      {:already_in_library, added, _status_map} -> {:already_in_library, added}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Requests a missing franchise movie on behalf of a guest.

  The shared rail renders a Request button rather than Add for a guest, and that
  event reaches `MediaLive.Show`, which has no `request_media` clause of its own.
  Without this handler the first click raises `FunctionClauseError` and takes the
  detail page down.
  """
  def request_franchise_movie(%{"tmdb_id" => tmdb_id}, socket) do
    with :ok <- Authorization.authorize_submit_request(socket),
         {parsed, ""} <- Integer.parse(tmdb_id),
         %FranchiseEntry{} = entry <- find_entry(socket.assigns.franchise, parsed) do
      submit_request(entry, socket)
    else
      {:unauthorized, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_add_result(tmdb_id, {:ok, {:ok, added}}, socket) do
    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> assign(:franchise, mark_owned(socket.assigns.franchise, added))
     |> put_flash(:info, "Added #{added.title} to your library")}
  end

  # Not an error from here up: the movie the user clicked is already in the
  # library, just under an entry this panel had not linked up yet.
  def handle_add_result(tmdb_id, {:ok, {:already_in_library, added}}, socket) do
    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> assign(:franchise, mark_owned(socket.assigns.franchise, added))
     |> put_flash(:info, "#{added.title} is already in your library")}
  end

  def handle_add_result(tmdb_id, {:ok, {:error, reason}}, socket) do
    Logger.warning("Franchise add failed for tmdb #{tmdb_id}: #{inspect(reason)}")

    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> put_flash(:error, "Could not add that movie: #{describe(reason)}")}
  end

  def handle_add_result(tmdb_id, {:exit, reason}, socket) do
    Logger.warning("Franchise add crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> clear_in_flight(tmdb_id)
     |> put_flash(:error, "Could not add that movie")}
  end

  ## Private

  # Populates request_status on load. Without this, a guest who requested a
  # missing entry and then reloaded the page would see the button revert to an
  # enabled Request, since mark_requested/3 only sets request_status in memory
  # for the life of the socket.
  #
  # request_status only ever affects the Request button, which only a guest
  # sees, so a viewer who cannot submit a request skips the query entirely
  # rather than paying for two unfiltered list_requests/1 calls whose result
  # they can never act on. Their entries keep FranchiseEntry's own nil
  # default for request_status.
  defp enrich_with_request_status(franchise, current_user) do
    if AccountsAuthorization.can_submit_request?(current_user) do
      status_map = MediaRequestHelpers.request_status_map()

      entries =
        Enum.map(franchise.entries, fn entry ->
          %{entry | request_status: Map.get(status_map, entry.tmdb_id)}
        end)

      %{franchise | entries: entries}
    else
      franchise
    end
  end

  defp find_entry(nil, _tmdb_id), do: nil

  defp find_entry(franchise, tmdb_id),
    do: Enum.find(franchise.entries, &(&1.tmdb_id == tmdb_id))

  # handle_request_media/3 reads provider_id, title and year off a plain map. A
  # FranchiseEntry carries tmdb_id rather than provider_id, so build the shape it
  # wants instead of widening the helper.
  defp submit_request(entry, socket) do
    item = %{provider_id: to_string(entry.tmdb_id), title: entry.title, year: entry.year}

    case MediaRequestHelpers.handle_request_media(item, :movie, socket.assigns.current_user.id) do
      {:ok, request, _status_updates} ->
        {:noreply,
         socket
         |> assign(
           :franchise,
           mark_requested(socket.assigns.franchise, entry.tmdb_id, request.status)
         )
         |> put_flash(:info, "#{request.title} requested. An admin will review it soon.")}

      {:error, reason} ->
        Logger.warning("Franchise request failed for tmdb #{entry.tmdb_id}: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Could not request that movie")}
    end
  end

  defp mark_requested(franchise, tmdb_id, status) do
    entries =
      Enum.map(franchise.entries, fn entry ->
        if entry.tmdb_id == tmdb_id do
          %{entry | request_status: status}
        else
          entry
        end
      end)

    %{franchise | entries: entries}
  end

  defp mark_in_flight(socket, tmdb_id) do
    assign(
      socket,
      :adding_franchise_tmdb_ids,
      MapSet.put(socket.assigns.adding_franchise_tmdb_ids, tmdb_id)
    )
  end

  defp clear_in_flight(socket, tmdb_id) do
    assign(
      socket,
      :adding_franchise_tmdb_ids,
      MapSet.delete(socket.assigns.adding_franchise_tmdb_ids, tmdb_id)
    )
  end

  defp mark_owned(nil, _added), do: nil

  defp mark_owned(franchise, added) do
    entries =
      Enum.map(franchise.entries, fn entry ->
        if entry.tmdb_id == added.tmdb_id do
          %{entry | in_library?: true, media_item_id: added.id, monitored: added.monitored}
        else
          entry
        end
      end)

    %{franchise | entries: entries, owned_count: Enum.count(entries, & &1.in_library?)}
  end

  defp describe({:changeset, changeset}),
    do: MediaAddHelpers.format_changeset_errors(changeset)

  defp describe({:metadata, _reason}), do: "the metadata service could not be reached"
  defp describe(reason), do: inspect(reason)
end
