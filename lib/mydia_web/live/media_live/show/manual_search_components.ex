defmodule MydiaWeb.MediaLive.Show.ManualSearchComponents do
  @moduledoc """
  Manual search dialog pieces: the result row and its column header, prior
  attempts and blocking downloads.

  Used by `MydiaWeb.MediaLive.Show.Modals.manual_search_modal/1`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents

  import MydiaWeb.MediaLive.Show.SearchHelpers,
    only: [get_search_quality_badge: 1, profile_score_breakdown: 2]

  import MydiaWeb.MediaLive.Show.Formatters,
    only: [format_search_size: 1, format_relative_time_short: 1]

  import MydiaWeb.MediaLive.Show.ScoreBreakdown
  import MydiaWeb.MediaLive.Show.TrackerTermsBadges, only: [terms_badges: 1]

  alias Mydia.Indexers.SearchResult
  alias MydiaWeb.Live.SearchResultRef
  alias MydiaWeb.MediaLive.Show.TrackerLimitNote

  # One grid template for the header row and every result row from `lg`, so
  # the columns line up. Below `lg` rows use daisyUI's default list-row flow
  # and the column cells are hidden.
  @row_grid "lg:grid-cols-[3rem_minmax(0,1fr)_5rem_4.5rem_3.5rem_9rem_2.5rem]"

  @doc "The `lg` grid template shared by the header and the result rows."
  def row_grid, do: @row_grid

  @doc """
  The indexer a row names: the tracker whose copy won the dedup merge, plus
  how many other trackers returned the same release.
  """
  def indexer_label(result) do
    case SearchResult.indexers(result) do
      [_one] -> result.indexer
      all -> gettext("%{indexer} +%{count}", indexer: result.indexer, count: length(all) - 1)
    end
  end

  attr :sort_by, :atom, required: true

  attr :profile?, :boolean, default: true

  @doc "Column labels above the results from `lg`; the sortable ones sort."
  def results_header(assigns) do
    assigns = assign(assigns, :grid, @row_grid)

    ~H"""
    <div
      id="manual-search-columns"
      class={[
        "sticky top-0 z-10 hidden gap-3 border-b border-base-300 bg-base-100 px-4 py-2 text-xs font-semibold text-base-content/60 lg:grid",
        @grid
      ]}
    >
      <.sort_header
        value={:quality}
        sort_by={@sort_by}
        label={if(@profile?, do: gettext("Score"), else: gettext("Seeds"))}
      />
      <span>{gettext("Release")}</span>
      <.sort_header value={:size} sort_by={@sort_by} label={gettext("Size")} />
      <.sort_header value={:seeders} sort_by={@sort_by} label={gettext("Seeds")} />
      <.sort_header value={:date} sort_by={@sort_by} label={gettext("Age")} />
      <span>{gettext("Indexer")}</span>
      <span class="sr-only">{gettext("Action")}</span>
    </div>
    """
  end

  attr :value, :atom, required: true
  attr :sort_by, :atom, required: true
  attr :label, :string, required: true

  defp sort_header(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="sort_search"
      phx-value-sort_by={@value}
      class={[
        "flex cursor-pointer items-center gap-0.5 text-left hover:text-base-content",
        @sort_by == @value && "text-primary"
      ]}
      aria-pressed={to_string(@sort_by == @value)}
    >
      {@label}
      <.icon :if={@sort_by == @value} name="hero-chevron-down-mini" class="w-3 h-3" />
    </button>
    """
  end

  # One manual search result. The template has several root nodes on purpose:
  # they render as direct children of the caller's `<li class="list-row">`,
  # so they are the grid items that line up under `results_header/1` from
  # `lg`. Do not wrap them in an element.
  attr :id, :string, required: true
  attr :result, SearchResult, required: true
  attr :manual_ranking_opts, :list, required: true

  def release_row(assigns) do
    result = assigns.result
    profile? = Keyword.get(assigns.manual_ranking_opts, :quality_profile) != nil
    # One scorer call per row: the audio badge needs the breakdown with or
    # without a profile; the score ring only with one.
    score_data = profile_score_breakdown(result, assigns.manual_ranking_opts)
    breakdown = score_data.breakdown
    score = score_data.score

    has_penalty =
      profile? &&
        (breakdown.seeder_penalty < 0.0 or breakdown.identity_penalty < 0.0 or
           not is_nil(breakdown.limit_violation))

    assigns =
      assign(assigns,
        profile?: profile?,
        score_data: score_data,
        breakdown: breakdown,
        audio: breakdown,
        score: score,
        ring_value: max(0, trunc(score)),
        has_penalty: has_penalty
      )

    ~H"""
    <%!-- Score display --%>
    <%= if @profile? do %>
      <.score_trigger
        id={"#{@id}-score-badge"}
        panel_id={"#{@id}-score-breakdown"}
        class={[
          "radial-progress text-sm font-bold cursor-pointer",
          @score >= 80 && "text-success",
          @score >= 50 && @score < 80 && "text-warning",
          @score < 50 && "text-error"
        ]}
        style={"--value:#{@ring_value}; --size:3rem; --thickness:4px;"}
        title={gettext("Show score breakdown")}
      >
        {trunc(@score)}
      </.score_trigger>
    <% else %>
      <%!-- No profile - just show seeders count (sorted by most seeders) --%>
      <div
        class={[
          "flex items-center justify-center w-12 h-12 rounded-full font-bold text-sm",
          seeder_tone(@result.seeders) == :high && "bg-success/20 text-success",
          seeder_tone(@result.seeders) == :mid && "bg-warning/20 text-warning",
          seeder_tone(@result.seeders) in [:low, :none] && "bg-base-300 text-base-content/70"
        ]}
        title={
          if is_nil(@result.seeders),
            do: gettext("No seeder count (Usenet)"),
            else: ngettext("%{count} seeder", "%{count} seeders", @result.seeders)
        }
      >
        <%= if is_nil(@result.seeders) do %>
          —
        <% else %>
          <.icon name="hero-arrow-up" class="w-3 h-3 mr-0.5" />
          {@result.seeders}
        <% end %>
      </div>
    <% end %>
    <%!-- Main content (title + badges) --%>
    <div class="list-col-grow flex-1 min-w-0">
      <%!-- Release Title --%>
      <div
        class="font-medium text-sm leading-tight mb-2 line-clamp-2 lg:line-clamp-1"
        title={@result.title}
      >
        {@result.title}
      </div>
      <%!-- Quality badges row --%>
      <div class="flex flex-wrap gap-1.5">
        <%!-- Resolution/Quality badge --%>
        <span class="badge badge-primary badge-sm">
          {get_search_quality_badge(@result)}
        </span>
        <%!-- Size badge (its own column from lg) --%>
        <span class="badge badge-ghost badge-sm font-mono lg:hidden">
          {format_search_size(@result)}
        </span>
        <%!-- Audio languages the release title claims --%>
        <MydiaWeb.AudioLanguageComponents.audio_badge
          id={"#{@id}-audio"}
          languages={@audio.audio_languages}
          assumed={@audio.audio_assumed}
          rank={@audio.language_rank}
        />
        <%!-- Seeders badge (its own column from lg) --%>
        <span
          class={[
            "badge badge-sm lg:hidden",
            seeder_tone(@result.seeders) == :high && "badge-success",
            seeder_tone(@result.seeders) == :mid && "badge-warning",
            seeder_tone(@result.seeders) == :low && "badge-error badge-outline",
            seeder_tone(@result.seeders) == :none && "badge-ghost"
          ]}
          title={if is_nil(@result.seeders), do: gettext("No seeder count (Usenet)")}
        >
          <%= if is_nil(@result.seeders) do %>
            —
          <% else %>
            <.icon name="hero-arrow-up" class="w-3 h-3 mr-0.5" />
            {@result.seeders}
          <% end %>
        </span>
        <%!-- Freeleech, upload multiplier and private tracker --%>
        <.terms_badges id={"#{@id}-terms"} terms={@result.terms} />
        <%!-- Indexer badge (its own column from lg) --%>
        <span class="lg:hidden">
          <.indexer_badge id={"#{@id}-indexer-badge-inline"} result={@result} />
        </span>
        <%!-- Tried before: failed for this target or blacklisted --%>
        <%= if attempt = visible_prior_attempt(@result) do %>
          <span
            id={"#{@id}-prior-attempt"}
            class="badge badge-error badge-outline badge-sm"
          >
            <%= if attempt.kind == :blacklisted do %>
              {gettext("Blacklisted")}
            <% else %>
              {failed_ago_text(format_relative_time_short(attempt.at))}
            <% end %>
          </span>
        <% end %>
      </div>
      <%!-- A live failure from this dialog wins over the recorded one --%>
      <%= if reason = Map.get(@result, :grab_failed) || visible_prior_reason(@result) do %>
        <div class="text-xs text-error mt-1 line-clamp-2">{reason}</div>
      <% end %>
      <TrackerLimitNote.limit_note id={"#{@id}-limit"} reason={Map.get(@result, :limit_reason)} />
      <.score_panel :if={@profile?} id={"#{@id}-score-breakdown"}>
        <.score_row
          label={gettext("Resolution")}
          value={@score_data.detected[:resolution]}
          score={@breakdown.quality}
          weight={60}
        />
        <.score_row
          label={gettext("Title match")}
          value={nil}
          score={@breakdown.title_match}
          weight={10}
        />
        <.score_row
          label={gettext("File Size")}
          value={
            if(@score_data.detected[:size_mb],
              do: "#{@score_data.detected[:size_mb]} MB",
              else: nil
            )
          }
          score={@breakdown.size}
          weight={5}
        />
        <div class="divider my-1 text-xs opacity-50">{gettext("Availability")}</div>
        <.score_row
          label={gettext("Seeders")}
          value={
            if is_nil(@result.seeders),
              do: gettext("No seeder count (Usenet)"),
              else: ngettext("%{count} peer", "%{count} peers", @result.seeders)
          }
          score={@breakdown.seeders}
          weight={30}
        />
        <div :if={@breakdown.freeleech > 0.0} id={"#{@id}-freeleech-score"}>
          <.score_row
            label={gettext("Freeleech bonus")}
            value={nil}
            score={@breakdown.freeleech}
            max={10}
          />
        </div>
        <%= if @has_penalty do %>
          <div class="divider my-1 text-xs opacity-50">{gettext("Penalties")}</div>
          <%= if @breakdown.limit_violation do %>
            <div id={"#{@id}-limit-violation"} class="text-xs text-warning py-1">
              {gettext("Outside profile limits: %{violation}",
                violation: @breakdown.limit_violation
              )}
            </div>
          <% end %>
          <.penalty_row
            label={gettext("Seeder penalty")}
            score={@breakdown.seeder_penalty}
          />
          <.penalty_row
            label={gettext("Identity mismatch")}
            score={@breakdown.identity_penalty}
          />
        <% end %>
      </.score_panel>
    </div>
    <%!-- Columns from lg; below lg the badges above carry the same facts --%>
    <div id={"#{@id}-size"} class="hidden self-center font-mono text-sm lg:block">
      {format_search_size(@result)}
    </div>
    <div id={"#{@id}-seeds"} class="hidden self-center lg:block">
      <span class={[
        "badge badge-sm",
        seeder_tone(@result.seeders) == :high && "badge-success",
        seeder_tone(@result.seeders) == :mid && "badge-warning",
        seeder_tone(@result.seeders) == :low && "badge-error badge-outline",
        seeder_tone(@result.seeders) == :none && "badge-ghost"
      ]}>
        <%= if is_nil(@result.seeders) do %>
          —
        <% else %>
          <.icon name="hero-arrow-up" class="w-3 h-3 mr-0.5" />{@result.seeders}
        <% end %>
      </span>
    </div>
    <div id={"#{@id}-age"} class="hidden self-center text-sm text-base-content/70 lg:block">
      {published_age(@result.published_at)}
    </div>
    <div id={"#{@id}-indexer"} class="hidden min-w-0 self-center truncate text-sm lg:block">
      <.indexer_badge id={"#{@id}-indexer-badge"} result={@result} />
    </div>
    <%!-- Download Action: icon-only on xs and in the lg column, where the
         title attribute is the label --%>
    <div class="flex items-center">
      <%= cond do %>
        <% Map.get(@result, :downloaded) -> %>
          <button
            class="btn btn-success max-sm:btn-square sm:btn-sm lg:btn-square btn-disabled"
            title={gettext("Grabbed")}
            disabled
          >
            <.icon name="hero-check" class="w-4 h-4" />
            <span class="hidden sm:inline lg:hidden">{gettext("Grabbed")}</span>
          </button>
        <% Map.get(@result, :duplicate) -> %>
          <button
            class="btn btn-ghost max-sm:btn-square sm:btn-sm lg:btn-square btn-disabled"
            title={gettext("Already downloading")}
            disabled
          >
            <.icon name="hero-check-circle" class="w-4 h-4" />
            <span class="hidden sm:inline lg:hidden">{gettext("Already downloading")}</span>
          </button>
        <% Map.get(@result, :downloading) -> %>
          <button
            class="btn btn-primary max-sm:btn-square sm:btn-sm lg:btn-square btn-disabled"
            title={gettext("Grabbing…")}
            disabled
          >
            <span class="loading loading-spinner loading-xs"></span>
            <span class="hidden sm:inline lg:hidden">{gettext("Grabbing…")}</span>
          </button>
        <% Map.get(@result, :grab_failed) -> %>
          <.retry_button result={@result} reason={Map.get(@result, :grab_failed)} />
        <% Map.get(@result, :prior_attempt) -> %>
          <.retry_button
            result={@result}
            reason={prior_attempt_reason(@result)}
            blacklisted={@result.prior_attempt.kind == :blacklisted}
          />
        <% true -> %>
          <button
            class="btn btn-primary max-sm:btn-square sm:btn-sm lg:btn-square group/dl [&.phx-click-loading]:btn-disabled [&.phx-click-loading]:pointer-events-none"
            phx-click="download_from_search"
            phx-value-ref={SearchResultRef.ref(@result)}
            title={gettext("Download this release")}
          >
            <span class="loading loading-spinner loading-xs hidden group-[.phx-click-loading]/dl:inline"></span>
            <.icon
              name="hero-arrow-down-tray"
              class="w-4 h-4 group-[.phx-click-loading]/dl:hidden"
            />
            <span class="hidden sm:inline lg:hidden">{gettext("Download")}</span>
          </button>
      <% end %>
    </div>
    """
  end

  # Colour band for a seeder count. nil means the release has no seeder concept
  # (Usenet), which is not the same as a measured 0.
  defp seeder_tone(nil), do: :none
  defp seeder_tone(n) when n >= 50, do: :high
  defp seeder_tone(n) when n >= 10, do: :mid
  defp seeder_tone(_n), do: :low

  # Only a DateTime has a relative age here; a missing or naive timestamp
  # renders nothing rather than a guess.
  defp published_age(%DateTime{} = published_at), do: format_relative_time_short(published_at)
  defp published_age(_published_at), do: nil

  # Indexer badge. One tracker: a direct link to the release's page when
  # usable, else a plain badge. Several (a dedup merge): a button opening a
  # menu of every tracker's page. The label truncates so a long tracker name
  # never runs into the download column; the title lists every tracker.
  #
  # The menu is a native popover with CSS anchor positioning (the
  # #downloads-more pattern), not an absolute dropdown-content: the results
  # list scrolls inside the dialog and would clip it. flip-block opens it
  # upward near the bottom edge.
  attr :id, :string, required: true
  attr :result, SearchResult, required: true

  defp indexer_badge(assigns) do
    sources = SearchResult.sources(assigns.result)
    names = Enum.map(sources, & &1.indexer)

    assigns =
      assign(assigns,
        info_page_url: SearchResult.info_page_url(assigns.result),
        links: Enum.map(sources, &{&1.indexer, SearchResult.usable_info_url(&1.info_url)}),
        merged?: length(sources) > 1,
        all_indexers: Enum.join(names, ", ")
      )

    ~H"""
    <%= cond do %>
      <% @merged? -> %>
        <button
          id={@id}
          type="button"
          class="badge badge-outline badge-sm max-w-full min-w-0 cursor-pointer gap-1 hover:border-primary hover:text-primary transition-colors"
          popovertarget={"#{@id}-menu"}
          style={"anchor-name:--#{@id}"}
          title={@all_indexers}
          aria-label={gettext("Trackers for this release: %{indexers}", indexers: @all_indexers)}
        >
          <span class="truncate">{indexer_label(@result)}</span>
          <.icon name="hero-chevron-down" class="w-3 h-3 shrink-0" />
        </button>
        <ul
          id={"#{@id}-menu"}
          popover
          class="dropdown dropdown-end menu bg-base-100 rounded-box w-64 p-2 shadow-lg border border-base-300 ms-0 whitespace-normal before:hidden"
          style={"position-anchor:--#{@id};position-try-fallbacks:flip-block"}
        >
          <li :for={{indexer, url} <- @links} class={[!url && "menu-disabled"]}>
            <a :if={url} href={url} target="_blank" rel="noopener noreferrer" class="gap-2">
              <span class="min-w-0 break-words">{indexer}</span>
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 shrink-0" />
            </a>
            <span :if={!url} class="break-words">{indexer}</span>
          </li>
        </ul>
      <% @info_page_url -> %>
        <a
          id={@id}
          href={@info_page_url}
          target="_blank"
          rel="noopener noreferrer"
          class="badge badge-outline badge-sm max-w-full min-w-0 gap-1 hover:border-primary hover:text-primary transition-colors"
          title={gettext("View this release on %{indexer}", indexer: @result.indexer)}
        >
          <span class="truncate">{indexer_label(@result)}</span>
          <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 shrink-0" />
        </a>
      <% true -> %>
        <%!-- No usable URL: a plain badge. It used to hide on xs screens, since a
             non-actionable badge earned no room in a dense mobile row; it now
             always shows because it is the only place a row names its trackers. --%>
        <span
          id={@id}
          class="badge badge-outline badge-sm max-w-full min-w-0"
          title={@all_indexers}
        >
          <span class="truncate">{indexer_label(@result)}</span>
        </span>
    <% end %>
    """
  end

  # The manual search dialog's "already downloading" banner: names the first
  # download that blocks every grab for this target, which opens the existing
  # download details modal, and counts the rest.
  attr :blocking, :list, required: true
  attr :context_type, :atom, default: nil

  def blocking_banner(assigns) do
    assigns =
      assigns
      |> assign(:first, hd(assigns.blocking))
      |> assign(:more, length(assigns.blocking) - 1)

    ~H"""
    <div id="manual-search-blocking" role="status" class="alert alert-info mx-4 mt-3 mb-1">
      <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
      <p class="text-sm">
        <button
          type="button"
          id="manual-search-blocking-download"
          class="link font-medium"
          phx-click="show_download_details"
          phx-value-download-id={@first.id}
        >
          {gettext("“%{title}”", title: @first.title)}
        </button>
        <%= if @more == 0 do %>
          {gettext("is already downloading.")}
        <% else %>
          {ngettext(
            "and %{count} more are already downloading.",
            "and %{count} more are already downloading.",
            @more
          )}
        <% end %>
        {blocked_target_text(@context_type, length(@blocking))}
      </p>
    </div>
    """
  end

  # One whole sentence per target rather than a translated target word
  # interpolated into a shared one (see lib/mydia_web/gettext/README.md).
  defp blocked_target_text(:episode, count) do
    ngettext(
      "New grabs for this episode are blocked until it finishes or is removed.",
      "New grabs for this episode are blocked until they finish or are removed.",
      count
    )
  end

  defp blocked_target_text(:season, count) do
    ngettext(
      "New grabs for this season are blocked until it finishes or is removed.",
      "New grabs for this season are blocked until they finish or are removed.",
      count
    )
  end

  defp blocked_target_text(_movie, count) do
    ngettext(
      "New grabs for this movie are blocked until it finishes or is removed.",
      "New grabs for this movie are blocked until they finish or are removed.",
      count
    )
  end

  # The retry action shared by a live failure in this dialog and a recorded
  # prior attempt; a release grabbed again goes through the same
  # download_from_search event as the plain Download button.
  attr :result, SearchResult, required: true
  attr :reason, :string, default: nil
  # A stored blacklist entry is not a failed download, and a manual grab
  # overrides it, so the button offers "Grab anyway" instead of a retry.
  attr :blacklisted, :boolean, default: false

  def retry_button(assigns) do
    ~H"""
    <button
      class="btn btn-error max-sm:btn-square sm:btn-sm lg:btn-square group/dl [&.phx-click-loading]:btn-disabled [&.phx-click-loading]:pointer-events-none"
      phx-click="download_from_search"
      phx-value-ref={SearchResultRef.ref(@result)}
      title={retry_title(@blacklisted, @reason)}
    >
      <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
      <span class="hidden sm:inline lg:hidden">{retry_label(@blacklisted)}</span>
    </button>
    """
  end

  defp retry_label(true), do: gettext("Grab anyway")
  defp retry_label(false), do: gettext("Failed — retry")

  defp retry_title(true, reason) when is_binary(reason),
    do: gettext("Blacklisted: %{reason}. Click to grab it anyway.", reason: reason)

  defp retry_title(false, reason) when is_binary(reason),
    do: gettext("Failed: %{reason} — click to retry", reason: reason)

  defp retry_title(_blacklisted, _reason), do: gettext("Download this release")

  # A live grab state from this dialog (in flight, done, duplicate or failed)
  # wins over the recorded prior attempt everywhere in the row.
  defp live_grab_state?(result) do
    Enum.any?(
      [:downloading, :downloaded, :duplicate, :grab_failed],
      &Map.get(result, &1)
    )
  end

  def visible_prior_attempt(result) do
    if live_grab_state?(result), do: nil, else: Map.get(result, :prior_attempt)
  end

  def visible_prior_reason(result) do
    if live_grab_state?(result), do: nil, else: prior_attempt_reason(result)
  end

  # format_relative_time_short/1 yields "now" or a bare "3h"; each reads
  # differently in a sentence.
  def failed_ago_text(ago) do
    if ago == pgettext("relative time", "now"),
      do: gettext("Failed just now"),
      else: gettext("Failed %{ago} ago", ago: ago)
  end

  # Blacklist reasons are machine slugs; failed downloads carry free text.
  def prior_attempt_reason(result) do
    case Map.get(result, :prior_attempt) do
      %{kind: :blacklisted, reason: reason} when is_binary(reason) ->
        MydiaWeb.StatusLabels.failure_category(reason)

      %{reason: reason} ->
        reason

      nil ->
        nil
    end
  end
end
