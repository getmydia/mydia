defmodule MydiaWeb.MediaLive.Show.FranchiseEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3, put_flash: 3, connected?: 1]

  alias Mydia.Media.Franchises
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

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
    {:noreply, assign(socket, :franchise, franchise)}
  end

  def handle_load_result({:ok, :none}, socket) do
    {:noreply, socket}
  end

  def handle_load_result({:exit, reason}, socket) do
    Logger.warning("Franchise lookup crashed: #{inspect(reason)}")
    {:noreply, socket}
  end

  @doc """
  Adds a missing franchise member, inheriting the viewed movie's quality profile
  and monitored flag.

  Permission is enforced against the `:can_create_media` assign computed once at
  mount, mirroring what already governs whether the add button renders at all;
  a crafted request against a hidden button still gets refused here.
  """
  def add_franchise_movie(%{"tmdb_id" => tmdb_id}, socket) do
    if socket.assigns.can_create_media do
      start_add(tmdb_id, socket)
    else
      {:noreply, socket}
    end
  end

  defp start_add(tmdb_id, socket) do
    case Integer.parse(tmdb_id) do
      {tmdb_id, ""} ->
        media_item = socket.assigns.media_item
        config = socket.assigns.metadata_config

        socket =
          socket
          |> assign(:adding_franchise_tmdb_id, tmdb_id)
          |> start_async(:add_franchise_movie, fn ->
            perform_add(media_item, tmdb_id, config)
          end)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Performs the add. Public so it can be exercised directly in tests without a
  live process.
  """
  def perform_add(media_item, tmdb_id, config) do
    MediaAddHelpers.handle_add_media_to_library(
      to_string(tmdb_id),
      :movie,
      %{},
      config,
      monitored: media_item.monitored,
      quality_profile_id: media_item.quality_profile_id
    )
    |> case do
      {:ok, added, _status_map} -> {:ok, added}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_add_result({:ok, {:ok, added}}, socket) do
    {:noreply,
     socket
     |> assign(:adding_franchise_tmdb_id, nil)
     |> assign(:franchise, mark_owned(socket.assigns.franchise, added))
     |> put_flash(:info, "Added #{added.title} to your library")}
  end

  def handle_add_result({:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:adding_franchise_tmdb_id, nil)
     |> put_flash(:error, "Could not add that movie: #{describe(reason)}")}
  end

  def handle_add_result({:exit, reason}, socket) do
    Logger.warning("Franchise add crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:adding_franchise_tmdb_id, nil)
     |> put_flash(:error, "Could not add that movie")}
  end

  ## Private

  defp mark_owned(nil, _added), do: nil

  defp mark_owned(franchise, added) do
    entries =
      Enum.map(franchise.entries, fn entry ->
        if entry.tmdb_id == added.tmdb_id do
          %{entry | in_library?: true, media_item_id: added.id}
        else
          entry
        end
      end)

    %{franchise | entries: entries, owned_count: Enum.count(entries, & &1.in_library?)}
  end

  defp describe({:changeset, changeset}),
    do: MediaAddHelpers.format_changeset_errors(changeset)

  defp describe({:metadata, reason}), do: "metadata lookup failed (#{inspect(reason)})"
  defp describe(reason), do: inspect(reason)
end
