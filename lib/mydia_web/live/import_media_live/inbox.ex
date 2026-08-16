defmodule MydiaWeb.ImportMediaLive.Inbox do
  @moduledoc """
  Components for the import inbox: files that were scanned and matched but not
  added to the library yet.

  This is a live query rather than session state, so approving a row takes
  effect immediately and there is nothing to persist between clicks. Every
  row this renders carries a real `MatchCandidate` (`Library.list_inbox_files/1`
  inner-joins on it), so a row's candidate is never `nil` -- only its
  `provider_id` can be, which is how an unidentified/failed file is told
  apart from a real match.
  """
  use MydiaWeb, :html

  alias MydiaWeb.ImportMediaLive.Components

  # Sentences for the handful of error shapes that can actually land in
  # `MatchCandidate.last_error` in production (traced through
  # `FileIngest.record_failure/2` and `FileIngest.format_error/1`):
  #
  #   * the literal string "no_match" -- ingest/3's own :no_match branch
  #   * an inspect/1 dump of an atom reason, e.g. ":no_matches_found" -- the
  #     shape `format_error/1`'s catch-all clause would produce for any of
  #     these atoms if something ever wrote one to this column directly
  #     (today none of them do -- the matching phase short-circuits before
  #     FileIngest for those -- but the field is nil-or-string, not a closed
  #     enum, so being able to render one legibly is cheap insurance)
  #
  # Anything not in this table (including the "{:library_type_mismatch, ...}"
  # inspect dump, which has no dedicated format_error/1 clause) is handled by
  # extract_tagged_message/1 below, or shown as-is as a last resort.
  @known_errors %{
    "no_match" => "No matching title was found for this file.",
    ":no_match" => "No matching title was found for this file.",
    ":no_matches_found" => "No matching title was found for this file.",
    ":low_confidence_match" =>
      "The best match found was not confident enough to add automatically.",
    ":unknown_media_type" => "Mydia could not tell whether this file is a movie or a TV episode.",
    ":enrichment_failed" => "Something went wrong while fetching this file's metadata."
  }

  attr :rows, :list, required: true
  attr :total, :integer, required: true
  attr :filter, :atom, default: :all
  attr :offset, :integer, default: 0
  attr :limit, :integer, default: 100
  attr :editing_file_id, :string, default: nil
  attr :editing_file_path, :string, default: nil
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []
  attr :batch_selected_ids, :any, default: MapSet.new()
  attr :batch_search_query, :string, default: ""
  attr :batch_search_results, :list, default: []
  attr :batch_selected_match, :map, default: nil
  attr :batch_season_value, :string, default: ""

  def inbox(assigns) do
    ~H"""
    <section id="import-inbox" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <h2 class="card-title">
            Waiting for review <span class="badge badge-neutral">{@total} {file_word(@total)}</span>
          </h2>

          <div class="flex items-center gap-2 flex-wrap">
            <%!--
              Lives in the header rather than in the batch toolbar, which is
              only rendered once something is already selected. This is the
              cheapest mitigation for the removed series re-match capability:
              without it, importing a 200 episode show means ticking 100
              checkboxes per page by hand before the batch editor appears.
            --%>
            <button
              :if={@total > 0}
              id="inbox-select-page"
              type="button"
              phx-click="batch_select_all"
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-check" class="w-4 h-4" /> Select all on this page
            </button>

            <select
              id="inbox-filter"
              name="filter"
              phx-change="filter_inbox"
              class="select select-bordered select-sm"
            >
              <option value="all" selected={@filter == :all}>Everything</option>
              <option value="low_confidence" selected={@filter == :low_confidence}>
                Unsure matches
              </option>
              <option value="unidentified" selected={@filter == :unidentified}>
                Could not identify
              </option>
            </select>
          </div>
        </div>

        <%!--
          Rendered here, above the list, rather than swapped into the row
          itself: rows come from a `phx-update="stream"` container, and
          LiveView only patches a stream item's DOM when it is explicitly
          re-inserted (`stream_insert/3` or a full `stream/3` reset) -- not
          when an unrelated assign like `editing_file_id` changes. Nesting
          the editor's visibility inside the streamed `<li>` would compute
          the right HTML on the server but never reach the client. A fixed
          location keyed by id sidesteps that entirely.
        --%>
        <div :if={@editing_file_id} class="pb-2">
          <Components.unmatched_file_list_item
            media_file_id={@editing_file_id}
            file_path={@editing_file_path}
            edit_form={@edit_form}
            search_results={@search_results}
          />
        </div>

        <p :if={@total == 0} class="opacity-70">{empty_message(@filter)}</p>

        <ul id="inbox-rows" phx-update="stream" class="divide-y divide-base-300">
          <li :for={{dom_id, row} <- @rows} id={dom_id} class="py-3 flex items-center gap-4">
            <% error = format_last_error(row.candidate.last_error) %>
            <input
              type="checkbox"
              id={"batch-toggle-#{row.media_file.id}"}
              class="checkbox checkbox-primary checkbox-sm"
              checked={MapSet.member?(@batch_selected_ids, row.media_file.id)}
              phx-click="batch_toggle_file"
              phx-value-id={row.media_file.id}
            />
            <div class="flex-1 min-w-0">
              <p class="font-medium truncate">{title_for(row)}</p>
              <p class="text-sm opacity-70 truncate">{row.media_file.relative_path}</p>
              <p :if={error} class="text-xs opacity-70 truncate">{error}</p>
            </div>

            <.confidence_badge candidate={row.candidate} />

            <button
              id={"edit-#{row.media_file.id}"}
              type="button"
              phx-click="edit_file"
              phx-value-id={row.media_file.id}
              class="btn btn-sm btn-ghost"
              title="Find or fix this file's match"
            >
              <.icon name="hero-magnifying-glass" class="w-4 h-4" />
            </button>

            <button
              id={"approve-#{row.media_file.id}"}
              phx-click="approve_file"
              phx-value-id={row.media_file.id}
              disabled={is_nil(row.candidate.provider_id)}
              class="btn btn-sm btn-primary"
            >
              Add
            </button>
          </li>
        </ul>

        <.pagination total={@total} offset={@offset} limit={@limit} />
      </div>
    </section>

    <Components.batch_edit_toolbar
      :if={MapSet.size(@batch_selected_ids) > 0}
      batch_selected_count={MapSet.size(@batch_selected_ids)}
      batch_search_query={@batch_search_query}
      batch_search_results={@batch_search_results}
      batch_selected_match={@batch_selected_match}
      batch_season_value={@batch_season_value}
    />
    """
  end

  attr :candidate, :map, required: true

  # No `nil`-candidate clause here on purpose: `list_inbox_files/1` inner-joins
  # on the candidate, so every row this component is handed carries one.
  defp confidence_badge(assigns) do
    ~H"""
    <span :if={library_type_mismatch?(@candidate)} class="badge badge-error badge-outline">
      Wrong library
    </span>
    <span
      :if={is_nil(@candidate.provider_id) and not library_type_mismatch?(@candidate)}
      class="badge badge-ghost"
    >
      No match
    </span>
    <span :if={@candidate.provider_id} class={["badge", confidence_class(@candidate.confidence)]}>
      {percent(@candidate.confidence)}
    </span>
    """
  end

  attr :total, :integer, required: true
  attr :offset, :integer, required: true
  attr :limit, :integer, required: true

  defp pagination(assigns) do
    ~H"""
    <div :if={@total > @limit} class="flex items-center justify-between pt-2">
      <p class="text-sm opacity-70">
        Showing {@offset + 1}-{min(@offset + @limit, @total)} of {@total}
      </p>
      <div class="join">
        <button
          id="inbox-prev-page"
          phx-click="inbox_page"
          phx-value-offset={max(@offset - @limit, 0)}
          disabled={@offset == 0}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>
        <button
          id="inbox-next-page"
          phx-click="inbox_page"
          phx-value-offset={@offset + @limit}
          disabled={@offset + @limit >= @total}
          class="join-item btn btn-sm"
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Turns a `MatchCandidate.last_error` value into a sentence a self-hosted
  user can read, instead of the raw Elixir term dump some error shapes fall
  back to before storage (see `FileIngest.format_error/1`).

  `last_error` is always `nil` or a plain `String.t()` by the time it reaches
  this column (`FileIngest.record_failure/2` only ever writes a string), so
  every clause here matches on string content, never a raw term. Anything
  unrecognised is returned as-is rather than hidden, so a shape this
  formatter doesn't know about yet is still legible instead of disappearing.
  """
  @spec format_last_error(String.t() | nil) :: String.t() | nil
  def format_last_error(nil), do: nil

  def format_last_error(raw) when is_binary(raw) do
    Map.get(@known_errors, raw) || extract_tagged_message(raw) || raw
  end

  # Unwraps `{:some_reason, "message"}`, the shape `inspect/1` produces for a
  # tagged error tuple with a human-written message inside it -- notably
  # `{:library_type_mismatch, message}`, which `FileIngest.format_error/1` has
  # no dedicated clause for and so falls through to `inspect/1`. The message
  # itself (written by `MetadataEnricher.validate_library_type_compatibility/2`)
  # is already a complete sentence, e.g. "Cannot add movies to a library path
  # configured for TV series only (path: /media/tv)" -- this only strips the
  # surrounding tuple syntax around it.
  defp extract_tagged_message(raw) do
    case Regex.run(~r/^\{:[a-z_]+,\s*"(.*)"\}$/s, raw) do
      [_, message] -> message
      _ -> nil
    end
  end

  # Whether a candidate's failure is specifically a library/media-type
  # mismatch (a movie found for a series-only library path, or vice versa),
  # as opposed to a genuine "nothing was found" failure. Both leave
  # `provider_id` nil -- the match was real, it just doesn't belong in this
  # library -- so this is what lets the inbox tell the two apart at a glance
  # instead of only in the fine print. See the moduledoc: the underlying data
  # was never at risk (MetadataEnricher already refuses to link a mismatched
  # file and FileIngest already records why), the gap was that nothing in the
  # UI singled these out from an honest "we don't know what this is" miss.
  defp library_type_mismatch?(%{last_error: nil}), do: false

  defp library_type_mismatch?(%{last_error: last_error}) do
    String.starts_with?(last_error, "{:library_type_mismatch,")
  end

  defp title_for(%{candidate: %{title: title}}) when is_binary(title), do: title
  defp title_for(%{media_file: file}), do: Path.basename(file.relative_path || "")

  defp empty_message(:all), do: "Nothing waiting. Start a run to find files."
  defp empty_message(_filter), do: "Nothing matches this filter."

  defp confidence_class(nil), do: "badge-ghost"
  defp confidence_class(c) when c >= 0.8, do: "badge-success"
  defp confidence_class(c) when c >= 0.5, do: "badge-warning"
  defp confidence_class(_), do: "badge-error"

  defp percent(nil), do: "?"
  defp percent(c), do: "#{round(c * 100)}%"

  defp file_word(1), do: "file"
  defp file_word(_), do: "files"
end
