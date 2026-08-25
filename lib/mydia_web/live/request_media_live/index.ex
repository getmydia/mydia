defmodule MydiaWeb.RequestMediaLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.{MediaRequests, Metadata}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:media_type, nil)
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:searching, false)
     |> assign(:metadata_config, Metadata.default_relay_config())
     |> assign(:requested_items, MapSet.new())
     |> assign(:requesting_index, nil)
     |> assign(:show_request_modal, false)
     |> assign(:request_modal_result, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :request_movie, params) do
    socket
    |> assign(:page_title, "Request Movie")
    |> assign(:media_type, :movie)
    |> maybe_trigger_search(params)
  end

  defp apply_action(socket, :request_series, params) do
    socket
    |> assign(:page_title, "Request Series")
    |> assign(:media_type, :tv_show)
    |> maybe_trigger_search(params)
  end

  # Auto-trigger search if a query parameter is provided
  defp maybe_trigger_search(socket, %{"q" => query}) when is_binary(query) and query != "" do
    send(self(), {:perform_search, query})

    socket
    |> assign(:search_query, query)
    |> assign(:searching, true)
  end

  defp maybe_trigger_search(socket, _params), do: socket

  ## Event Handlers

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    send(self(), {:perform_search, query})

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:searching, true)
     |> assign(:search_results, [])}
  end

  def handle_event("open_request_modal", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    result = Enum.at(socket.assigns.search_results, index)

    {:noreply,
     socket
     |> assign(:show_request_modal, true)
     |> assign(:request_modal_result, result)
     |> assign(:request_modal_index, index)
     |> assign_request_form()}
  end

  def handle_event("close_request_modal", _params, socket) do
    {:noreply, assign(socket, :show_request_modal, false)}
  end

  def handle_event("validate_request", %{"request" => request_params}, socket) do
    changeset = validate_request(request_params, socket.assigns)

    {:noreply, assign(socket, :request_form, to_form(changeset, as: :request))}
  end

  def handle_event("submit_request_modal", %{"request" => request_params}, socket) do
    changeset = validate_request(request_params, socket.assigns)

    if changeset.valid? do
      request_attrs =
        build_request_attrs(socket.assigns.request_modal_result, request_params, socket.assigns)

      case MediaRequests.create_request(request_attrs) do
        {:ok, _media_request} ->
          result = socket.assigns.request_modal_result

          {:noreply,
           socket
           |> assign(:show_request_modal, false)
           |> assign(:requested_items, MapSet.put(socket.assigns.requested_items, result.id))
           |> put_flash(:info, "Request submitted successfully! An admin will review it soon.")}

        {:error, :duplicate_media} ->
          {:noreply,
           socket
           |> assign(:request_form, to_form(changeset, as: :request))
           |> put_flash(:error, "This media item already exists in the library")}

        {:error, :duplicate_request} ->
          {:noreply,
           socket
           |> assign(:request_form, to_form(changeset, as: :request))
           |> put_flash(:error, "A request for this media already exists")}

        {:error, changeset} ->
          {:noreply, assign(socket, :request_form, to_form(changeset, as: :request))}
      end
    else
      {:noreply, assign(socket, :request_form, to_form(changeset, as: :request))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  ## Async Handlers

  @impl true
  def handle_info({:perform_search, query}, socket) do
    media_type_filter =
      case socket.assigns.media_type do
        :movie -> :movie
        :tv_show -> :tv_show
        _ -> nil
      end

    opts = [media_type: media_type_filter]

    case Metadata.search(socket.assigns.metadata_config, query, opts) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:search_results, results)
         |> assign(:searching, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:searching, false)
         |> put_flash(:error, "Search failed: #{inspect(reason)}")}
    end
  end

  ## Private Helpers

  defp assign_request_form(socket) do
    changeset =
      {%{},
       %{
         requester_notes: :string
       }}
      |> Ecto.Changeset.cast(
        %{
          requester_notes: ""
        },
        [:requester_notes]
      )

    assign(socket, :request_form, to_form(changeset, as: :request))
  end

  defp validate_request(params, _assigns) do
    types = %{
      requester_notes: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
  end

  defp build_request_attrs(result, params, assigns) do
    media_type_string = if assigns.media_type == :movie, do: "movie", else: "tv_show"

    base = %{
      media_type: media_type_string,
      title: result.title || result.name,
      original_title: result.original_title || result.original_name,
      year: extract_year(result),
      imdb_id: result.imdb_id,
      poster_path: result.poster_path,
      requester_notes: params["requester_notes"],
      requester_id: assigns.current_user.id
    }

    # For TV shows from TVDB, store tvdb_id; otherwise store tmdb_id
    if assigns.media_type == :tv_show and Map.get(result, :provider) == :tvdb do
      Map.put(base, :tvdb_id, result.id)
    else
      Map.put(base, :tmdb_id, result.id)
    end
  end

  defp extract_year(metadata) do
    cond do
      metadata.year ->
        metadata.year

      metadata.release_date || metadata.first_air_date ->
        date_value = metadata.release_date || metadata.first_air_date
        extract_year_from_date(date_value)

      true ->
        nil
    end
  end

  defp extract_year_from_date(%Date{} = date), do: date.year

  defp extract_year_from_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date.year
      _ -> nil
    end
  end

  defp extract_year_from_date(_), do: nil

  defp get_poster_url(result) do
    case result.poster_path do
      nil -> "/images/no-poster.svg"
      path -> ImageUrl.poster_url(path)
    end
  end

  defp format_year(nil), do: "N/A"

  defp format_year(result) do
    date_str = result.release_date || result.first_air_date

    case date_str do
      nil ->
        "N/A"

      str ->
        case Date.from_iso8601(str) do
          {:ok, date} -> to_string(date.year)
          _ -> "N/A"
        end
    end
  end

  defp format_rating(nil), do: "N/A"

  defp format_rating(rating) when is_float(rating) do
    Float.round(rating, 1) |> to_string()
  end

  defp format_rating(rating), do: to_string(rating)
end
