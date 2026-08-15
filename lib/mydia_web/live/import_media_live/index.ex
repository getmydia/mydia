defmodule MydiaWeb.ImportMediaLive.Index do
  @moduledoc """
  Import Media: start a run, watch it, stop it, and work the inbox it leaves.

  There is no wizard and no session state. The run lives in Oban and the inbox
  is a live query, so this LiveView holds no import progress of its own beyond
  what it reads back.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Metadata, Settings}
  alias Mydia.Jobs.ImportRun, as: ImportRunJob
  alias Mydia.Library.FileIngest
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.{Inbox, RunControl}

  # The inbox is a single global queue across every library path (matching
  # how @active_run/@outcome_run already treat "the import run" as one thing
  # rather than one per path), paged at a fixed size rather than a
  # user-configurable one -- there is no UI for changing it yet.
  @inbox_page_size 100

  @impl true
  def mount(_params, _session, socket) do
    library_paths = Settings.list_library_paths()
    active_run = Enum.find_value(library_paths, &Library.active_import_run(&1.id))

    # No run in flight: fall back to the most recent one so a finished,
    # failed, or stopped run stays visible after a reload instead of the
    # panel silently reverting to a blank start form. active_import_run/1
    # itself stays untouched -- Task 6's coordinator and Task 2's uniqueness
    # guard both depend on it excluding terminal states.
    outcome_run =
      if active_run do
        nil
      else
        Enum.find_value(library_paths, &Library.last_import_run(&1.id))
      end

    run_to_watch = active_run || outcome_run

    if connected?(socket) and run_to_watch do
      Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run_to_watch.id))
    end

    {:ok,
     socket
     |> assign(:page_title, "Import Media")
     |> assign(:library_paths, library_paths)
     |> assign(:active_run, active_run)
     |> assign(:outcome_run, outcome_run)
     |> assign(:inbox_filter, :all)
     |> assign(:inbox_offset, 0)
     |> assign(:inbox_limit, @inbox_page_size)
     |> assign(:editing_file_id, nil)
     |> assign(:editing_file_path, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_results, [])
     |> assign(:batch_selected_ids, MapSet.new())
     |> assign(:batch_search_query, "")
     |> assign(:batch_search_results, [])
     |> assign(:batch_selected_match, nil)
     |> assign(:batch_season_value, "")
     # A row is `%{media_file:, candidate:}`, not a struct with its own :id --
     # stream/3 needs to be told how to derive a DOM id from that shape.
     |> stream_configure(:inbox_rows, dom_id: &"inbox-row-#{&1.media_file.id}")
     |> load_inbox()}
  end

  @impl true
  def handle_event("start_run", %{"library_path_id" => path_id, "mode" => mode}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      attrs = %{
        library_path_id: path_id,
        user_id: socket.assigns.current_user.id,
        mode: String.to_existing_atom(mode)
      }

      case Library.create_import_run(attrs) do
        {:ok, run} ->
          %{"import_run_id" => run.id}
          |> ImportRunJob.new()
          |> Oban.insert!()

          if connected?(socket) do
            Phoenix.PubSub.subscribe(Mydia.PubSub, ImportRunJob.progress_topic(run.id))
          end

          {:noreply,
           socket
           |> assign(:active_run, run)
           |> assign(:outcome_run, nil)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That library is already being imported.")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("stop_run", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      case socket.assigns.active_run do
        nil ->
          {:noreply, socket}

        run ->
          {:ok, stopping} = Library.request_import_run_stop(Library.get_import_run(run.id))
          {:noreply, assign(socket, :active_run, stopping)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("filter_inbox", %{"filter" => filter}, socket) do
    {:noreply,
     socket
     |> assign(:inbox_filter, String.to_existing_atom(filter))
     |> assign(:inbox_offset, 0)
     |> load_inbox()}
  end

  def handle_event("inbox_page", %{"offset" => offset}, socket) do
    {:noreply,
     socket
     |> assign(:inbox_offset, String.to_integer(offset))
     |> load_inbox()}
  end

  def handle_event("approve_file", %{"id" => media_file_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      media_file = Library.get_media_file!(media_file_id)

      case Library.list_match_candidates(media_file_id) do
        [%{provider_id: provider_id} = candidate | _] when not is_nil(provider_id) ->
          match = candidate_to_match(candidate)

          case FileIngest.ingest(media_file, match, policy: :create_items, threshold: 0.0) do
            {:linked, _media_item} ->
              {:noreply,
               socket
               |> forget_file(media_file_id)
               |> put_flash(:info, "Added #{candidate.title}")
               |> load_inbox()}

            _ ->
              {:noreply, put_flash(socket, :error, "Could not add #{candidate.title}")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "That file has no match to add yet.")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("edit_file", %{"id" => id}, socket) do
    media_file = Library.get_media_file!(id)
    candidate = List.first(Library.list_match_candidates(id))

    form = %{
      "title" => (candidate && candidate.title) || "",
      "provider_id" => (candidate && candidate.provider_id) || "",
      "type" => (candidate && candidate.media_type) || "movie",
      "season" => season_string(candidate),
      "episodes" => episodes_string(candidate)
    }

    {:noreply,
     socket
     |> assign(:editing_file_id, id)
     |> assign(:editing_file_path, media_file.relative_path)
     |> assign(:edit_form, form)
     |> assign(:search_results, [])}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_file_id, nil)
     |> assign(:editing_file_path, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_results, [])}
  end

  # The per-file search input is `name="edit_form[title]"` (it doubles as the
  # form field save_edit reads), so a phx-change on it arrives nested under
  # "edit_form" rather than as a bare "query" -- unlike the batch toolbar's
  # standalone search box below, which has nothing else to namespace under.
  def handle_event("search_metadata", %{"edit_form" => %{"title" => query}}, socket) do
    {:noreply, assign(socket, :search_results, search_metadata(query))}
  end

  def handle_event("select_search_result", params, socket) do
    form =
      socket.assigns.edit_form
      |> Map.put("title", params["title"])
      |> Map.put("provider_id", params["provider_id"])
      |> Map.put("type", params["type"])

    {:noreply,
     socket
     |> assign(:edit_form, form)
     |> assign(:search_results, [])}
  end

  def handle_event("save_edit", %{"edit_form" => params}, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         id when is_binary(id) <- socket.assigns.editing_file_id do
      {:ok, _candidate} =
        Library.upsert_match_candidate(%{
          media_file_id: id,
          rank: 0,
          provider_type: "tmdb",
          provider_id: params["provider_id"],
          title: params["title"],
          media_type: params["type"],
          # A human typed this, so it is certain by definition.
          confidence: 1.0,
          parsed_info: %{
            "season" => parse_int(params["season"]),
            "episodes" => parse_episode_list(params["episodes"])
          },
          attempts: 0,
          last_error: nil
        })

      {:noreply,
       socket
       |> assign(:editing_file_id, nil)
       |> assign(:editing_file_path, nil)
       |> assign(:edit_form, nil)
       |> put_flash(:info, "Match updated")
       |> load_inbox()}
    else
      {:unauthorized, socket} -> {:noreply, socket}
      nil -> {:noreply, socket}
    end
  end

  # Every batch-selection handler below ends with load_inbox/1 even though
  # none of them write to the database: a checkbox's `checked` state lives
  # inside the `phx-update="stream"` row list, and LiveView only patches an
  # already-rendered stream item's content on an explicit stream operation,
  # not because some other assign (`batch_selected_ids`) changed. load_inbox/1
  # already exists for exactly this "make the rendered rows match current
  # state" purpose (see its own moduledoc note), so reusing it here -- a full
  # re-stream of the current page -- is the same pattern the rest of this
  # module already relies on, not a new one.
  def handle_event("batch_toggle_file", %{"id" => id}, socket) do
    selected = socket.assigns.batch_selected_ids

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, socket |> assign(:batch_selected_ids, selected) |> load_inbox()}
  end

  def handle_event("batch_select_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_selected_ids, MapSet.new(socket.assigns.inbox_row_ids))
     |> load_inbox()}
  end

  def handle_event("batch_deselect_all", _params, socket) do
    {:noreply, socket |> assign(:batch_selected_ids, MapSet.new()) |> load_inbox()}
  end

  def handle_event("batch_search", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(:batch_search_query, query)
     |> assign(:batch_search_results, search_metadata(query))}
  end

  def handle_event("batch_select_search_result", params, socket) do
    match = %{
      title: params["title"],
      provider_id: params["provider_id"],
      year: if(params["year"] not in [nil, ""], do: params["year"]),
      type: params["type"]
    }

    {:noreply,
     socket
     |> assign(:batch_selected_match, match)
     |> assign(:batch_search_query, match.title)
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_clear_match", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_selected_match, nil)
     |> assign(:batch_search_query, "")
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_update_season", %{"value" => value}, socket) do
    {:noreply, assign(socket, :batch_season_value, value)}
  end

  def handle_event("batch_apply", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      selected_ids = MapSet.to_list(socket.assigns.batch_selected_ids)
      match = socket.assigns.batch_selected_match
      season = socket.assigns.batch_season_value

      if match == nil and String.trim(season || "") == "" do
        {:noreply,
         put_flash(
           socket,
           :error,
           "No changes to apply. Select a series/movie or enter a season number."
         )}
      else
        Enum.each(selected_ids, &apply_batch_change(&1, match, season))

        {:noreply,
         socket
         |> assign(:batch_selected_ids, MapSet.new())
         |> assign(:batch_search_query, "")
         |> assign(:batch_search_results, [])
         |> assign(:batch_selected_match, nil)
         |> assign(:batch_season_value, "")
         |> put_flash(:info, "Batch edit applied to #{length(selected_ids)} file(s)")
         |> load_inbox()}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:import_run_progress, run}, socket) do
    socket =
      if run.status in [:running, :stopping] do
        assign(socket, :active_run, run)
      else
        # Terminal: don't just clear the panel. Keep the run visible as an
        # outcome so a user who walked away comes back to "it finished" /
        # "it failed" / "it stopped", not a blank start form that looks like
        # nothing ever happened.
        socket
        |> assign(:active_run, nil)
        |> assign(:outcome_run, run)
      end

    {:noreply, socket}
  end

  def handle_info({:import_run_current_file, name}, socket) do
    case socket.assigns.active_run do
      nil -> {:noreply, socket}
      run -> {:noreply, assign(socket, :active_run, %{run | current_file: name})}
    end
  end

  # threshold: 0.0 below is deliberate. A human pressed Add, so their
  # judgement replaces the confidence gate rather than being second-guessed
  # by it -- the same reasoning FileIngest.default_threshold/0 documents for
  # unattended mode, inverted: a person is standing in for the gate here.
  defp candidate_to_match(candidate) do
    %{
      provider_id: candidate.provider_id,
      provider_type: String.to_existing_atom(candidate.provider_type || "tmdb"),
      title: candidate.title,
      year: candidate.year,
      match_confidence: candidate.confidence || 1.0,
      metadata: %{},
      manually_edited: true,
      parsed_info: restore_parsed_info(candidate)
    }
  end

  defp restore_parsed_info(candidate) do
    parsed = candidate.parsed_info || %{}

    %{
      type: String.to_existing_atom(candidate.media_type || "movie"),
      season: Map.get(parsed, "season"),
      episodes: Map.get(parsed, "episodes") || []
    }
  end

  # The inbox is a live query, not socket state: every mutation that can
  # change it (approving a row, changing the filter, paging) reloads from the
  # database rather than patching @streams.inbox_rows by hand, so it can
  # never drift from what a fresh page load would show.
  defp load_inbox(socket) do
    filter = socket.assigns.inbox_filter
    total = Library.count_inbox_files(filter: filter)

    # Clamp rather than render a page past the end: approving the last row on
    # the last page (or switching to a filter with fewer results) would
    # otherwise leave the offset pointing beyond `total`, showing an empty
    # list even though earlier rows still exist.
    offset =
      if socket.assigns.inbox_offset > 0 and socket.assigns.inbox_offset >= total do
        max(total - socket.assigns.inbox_limit, 0)
      else
        socket.assigns.inbox_offset
      end

    rows =
      Library.list_inbox_files(filter: filter, limit: socket.assigns.inbox_limit, offset: offset)

    socket
    |> assign(:inbox_total, total)
    |> assign(:inbox_offset, offset)
    # Kept alongside the stream, not derived from it: LiveView streams are
    # write-only from the server's perspective (see the streams guidance --
    # Enum.filter/2 and friends don't work on them), and batch_select_all
    # needs the current page's ids to select.
    |> assign(:inbox_row_ids, Enum.map(rows, & &1.media_file.id))
    |> stream(:inbox_rows, rows, reset: true)
  end

  # Clears any editing/selection state pointing at a file that just left the
  # inbox (approved), so a stale id doesn't linger in @editing_file_id or
  # @batch_selected_ids referring to a row that no longer streams.
  defp forget_file(socket, media_file_id) do
    socket =
      if socket.assigns.editing_file_id == media_file_id do
        socket
        |> assign(:editing_file_id, nil)
        |> assign(:editing_file_path, nil)
        |> assign(:edit_form, nil)
      else
        socket
      end

    assign(
      socket,
      :batch_selected_ids,
      MapSet.delete(socket.assigns.batch_selected_ids, media_file_id)
    )
  end

  defp season_string(nil), do: ""

  defp season_string(candidate) do
    case Map.get(candidate.parsed_info || %{}, "season") do
      nil -> ""
      season -> to_string(season)
    end
  end

  defp episodes_string(nil), do: ""

  defp episodes_string(candidate) do
    (candidate.parsed_info || %{})
    |> Map.get("episodes", [])
    |> Enum.join(", ")
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_episode_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_episode_list(_), do: []

  # Shared by the per-file editor and the batch toolbar's search box. Both
  # media types are always searched: the inbox is a single global queue
  # across every library path (see the moduledoc), so there is no one
  # library type to filter by the way the old per-path wizard could.
  defp search_metadata(query) do
    if String.length(String.trim(query)) < 2 do
      []
    else
      config = Metadata.default_relay_config()

      movie =
        case Metadata.search(config, query, media_type: :movie) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "movie"))
          _ -> []
        end

      tv =
        case Metadata.search(config, query, media_type: :tv_show) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "tv_show"))
          _ -> []
        end

      Enum.take(movie ++ tv, 10)
    end
  end

  # Merges a batch edit into a file's existing rank-0 candidate instead of
  # overwriting it outright, so applying only a season number (no match
  # change selected) does not blank out a title/provider an earlier edit or
  # the matching phase already set.
  defp apply_batch_change(media_file_id, match, season) do
    existing = List.first(Library.list_match_candidates(media_file_id))
    parsed_info = (existing && existing.parsed_info) || %{}

    attrs = %{
      media_file_id: media_file_id,
      rank: 0,
      attempts: 0,
      last_error: nil,
      provider_type: (existing && existing.provider_type) || "tmdb",
      provider_id: existing && existing.provider_id,
      title: existing && existing.title,
      media_type: existing && existing.media_type,
      confidence: existing && existing.confidence
    }

    attrs =
      if match do
        %{
          attrs
          | provider_type: "tmdb",
            provider_id: match.provider_id,
            title: match.title,
            media_type: match.type,
            confidence: 1.0
        }
      else
        attrs
      end

    parsed_info =
      if String.trim(season || "") != "" do
        Map.put(parsed_info, "season", parse_int(season))
      else
        parsed_info
      end

    Library.upsert_match_candidate(Map.put(attrs, :parsed_info, parsed_info))
  end
end
