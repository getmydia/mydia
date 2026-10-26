defmodule MydiaWeb.MediaLive.Show.ManualSearchComponents do
  @moduledoc """
  Manual search dialog pieces for prior attempts and blocking downloads.

  Used by `MydiaWeb.MediaLive.Show.Modals.manual_search_modal/1`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents
  import MydiaWeb.MediaLive.Show.SearchHelpers, only: [get_search_quality_badge: 1]

  alias Mydia.Indexers.SearchResult

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
      class="btn btn-error btn-sm group/dl [&.phx-click-loading]:btn-disabled [&.phx-click-loading]:pointer-events-none"
      phx-click="download_from_search"
      phx-value-download-url={@result.download_url}
      phx-value-title={@result.title}
      phx-value-indexer={@result.indexer}
      phx-value-size={@result.size}
      phx-value-seeders={@result.seeders || 0}
      phx-value-leechers={@result.leechers || 0}
      phx-value-quality={get_search_quality_badge(@result)}
      title={retry_title(@blacklisted, @reason)}
    >
      <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
      <span class="hidden sm:inline">{retry_label(@blacklisted)}</span>
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
