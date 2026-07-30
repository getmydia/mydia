defmodule MydiaWeb.AdminReleaseBlacklistLive.Index do
  @moduledoc """
  Admin LiveView for managing the release blacklist (issue #123).

  Operators can:

    * View blacklisted `(indexer, guid)` rows ordered by most recent.
    * Filter by `failure_reason`.
    * "Block forever" — clear `expires_at` so a row never expires.
    * "Remove" — delete the row entirely (instant un-blacklist).

  Rows expire automatically via `Mydia.Jobs.BlacklistCleanup` based on the
  configured TTL (default 30 days).
  """

  use MydiaWeb, :live_view

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Client.FailureCategory

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Release Blacklist")
     |> assign(:active_tab, :release_blacklist)
     |> assign(:failure_reason_filter, "")
     |> assign(:page, 1)
     |> assign(:page_size, @page_size)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  ## Event Handlers

  @impl true
  def handle_event("filter", %{"failure_reason" => failure_reason}, socket) do
    {:noreply,
     socket
     |> assign(:failure_reason_filter, failure_reason)
     |> assign(:page, 1)
     |> load_data()}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply,
     socket
     |> assign(:failure_reason_filter, "")
     |> assign(:page, 1)
     |> load_data()}
  end

  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.page - 1)
    {:noreply, socket |> assign(:page, page) |> load_data()}
  end

  def handle_event("next_page", _params, socket) do
    total = socket.assigns.total_count
    page_size = socket.assigns.page_size
    max_page = max(1, ceil(total / page_size))
    page = min(max_page, socket.assigns.page + 1)
    {:noreply, socket |> assign(:page, page) |> load_data()}
  end

  def handle_event("block_forever", %{"id" => id}, socket) do
    case Blacklists.block_forever(id) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Release will be blocked forever.")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Blacklist row not found.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update blacklist row.")}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    case Blacklists.remove(id) do
      {:ok, _row} ->
        {:noreply,
         socket
         |> put_flash(:info, "Release removed from blacklist.")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Blacklist row not found.")}
    end
  end

  ## Private Helpers

  defp load_data(socket) do
    failure_reason = socket.assigns.failure_reason_filter
    page = socket.assigns.page
    page_size = socket.assigns.page_size

    list_opts =
      [limit: page_size, offset: (page - 1) * page_size]
      |> maybe_put(:failure_reason, failure_reason)

    count_opts = maybe_put([], :failure_reason, failure_reason)

    rows = Blacklists.list(list_opts)
    total_count = Blacklists.count(count_opts)
    failure_reasons = Blacklists.list_failure_reasons()

    socket
    |> assign(:rows, rows)
    |> assign(:total_count, total_count)
    |> assign(:failure_reasons, failure_reasons)
  end

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_datetime(nil), do: "never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp expires_label(nil), do: "forever"

  defp expires_label(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if DateTime.compare(dt, now) == :lt do
      "expired"
    else
      format_datetime(dt)
    end
  end

  defp total_pages(0, _page_size), do: 1
  defp total_pages(total, page_size), do: max(1, ceil(total / page_size))

  # Slugs are stable identifiers; the operator reads the label. Unknown
  # slugs (rows written by a newer version) humanize rather than raise.
  defp reason_label(slug), do: FailureCategory.label(slug)
end
