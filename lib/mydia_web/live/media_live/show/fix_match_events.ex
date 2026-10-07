defmodule MydiaWeb.MediaLive.Show.FixMatchEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  alias Mydia.Media.FixMatch
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 2]

  require Logger

  def open(_params, socket) do
    case Authorization.authorize_delete_media(socket) do
      :ok ->
        item = socket.assigns.media_item

        {:noreply,
         assign(socket, :fix_match, %{
           step: :search,
           form: form(item.title, item.year),
           results: [],
           searching?: false,
           error: nil,
           picked: nil,
           adopting?: false
         })}

      {:unauthorized, socket} ->
        {:noreply, socket}
    end
  end

  def close(_params, socket), do: {:noreply, assign(socket, :fix_match, nil)}

  def search(_params, %{assigns: %{fix_match: nil}} = socket), do: {:noreply, socket}

  def search(%{"fix_match" => %{"query" => query} = params}, socket) when is_binary(query) do
    item = socket.assigns.media_item
    scope = socket.assigns.current_scope
    config = socket.assigns[:metadata_config]
    year = parse_year(params["year"])
    trimmed = String.trim(query)

    if trimmed == "" do
      {:noreply, update_fix_match(socket, form: form(query, year))}
    else
      {:noreply,
       socket
       |> update_fix_match(form: form(query, year), searching?: true, error: nil)
       |> start_async(:fix_match_search, fn ->
         FixMatch.search(item, trimmed, year, scope, config)
       end)}
    end
  end

  def search(_params, socket), do: {:noreply, socket}

  def handle_search_async({:ok, {:ok, results}}, socket),
    do: {:noreply, update_fix_match(socket, results: results, searching?: false)}

  def handle_search_async({:ok, {:error, reason}}, socket) do
    {:noreply,
     update_fix_match(socket, searching?: false, error: "Search failed: #{inspect(reason)}")}
  end

  def handle_search_async({:exit, reason}, socket) do
    Logger.error("Fix match search crashed: #{inspect(reason)}")
    {:noreply, update_fix_match(socket, searching?: false, error: "Search failed unexpectedly")}
  end

  def pick(_params, %{assigns: %{fix_match: nil}} = socket), do: {:noreply, socket}

  def pick(%{"provider_id" => provider_id}, socket) do
    current = FixMatch.current_provider_id(socket.assigns.media_item)

    picked =
      Enum.find(socket.assigns.fix_match.results, &(to_string(&1.provider_id) == provider_id))

    if picked && provider_id != current do
      {:noreply, update_fix_match(socket, step: :confirm, picked: picked)}
    else
      {:noreply, socket}
    end
  end

  def back(_params, socket),
    do: {:noreply, update_fix_match(socket, step: :search, picked: nil)}

  def confirm(_params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket),
         %{picked: %{} = picked} <- socket.assigns.fix_match do
      item = socket.assigns.media_item
      scope = socket.assigns.current_scope
      config = socket.assigns[:metadata_config]

      {:noreply,
       socket
       |> update_fix_match(adopting?: true)
       |> start_async(:fix_match_adopt, fn -> FixMatch.adopt(scope, item, picked, config) end)}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_adopt_async({:ok, {:ok, updated}}, socket) do
    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> assign(:media_item, load_media_item(socket.assigns.current_scope, updated.id))
     |> put_flash(:info, "Match changed to #{updated.title}")}
  end

  def handle_adopt_async({:ok, {:error, {:already_in_library, other}}}, socket) do
    noun = if other.type == "movie", do: "movie", else: "show"

    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(
       :error,
       "#{other.title} is already in your library. " <>
         "Use \"Not this #{noun}\" on the files to move them there."
     )}
  end

  def handle_adopt_async({:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:error, "Could not change the match: #{inspect(reason)}")}
  end

  def handle_adopt_async({:exit, reason}, socket) do
    Logger.error("Fix match adopt crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:fix_match, nil)
     |> put_flash(:error, "Could not change the match")}
  end

  defp form(query, year),
    do: to_form(%{"query" => query || "", "year" => year && to_string(year)}, as: :fix_match)

  # The modal may close while a search is in flight or a stale event arrives.
  defp update_fix_match(%{assigns: %{fix_match: nil}} = socket, _changes), do: socket

  defp update_fix_match(socket, changes),
    do: assign(socket, :fix_match, Map.merge(socket.assigns.fix_match, Map.new(changes)))

  defp parse_year(nil), do: nil

  defp parse_year(value) do
    case Integer.parse(String.trim(value)) do
      {year, ""} when year > 1800 and year < 3000 -> year
      _ -> nil
    end
  end
end
