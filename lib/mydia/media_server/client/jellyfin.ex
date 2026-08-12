defmodule Mydia.MediaServer.Client.Jellyfin do
  @moduledoc """
  Jellyfin media server adapter.
  """

  @behaviour Mydia.MediaServer.Client

  alias Mydia.MediaServer.Error

  require Logger

  @impl true
  def test_connection(config) do
    # Jellyfin system info: /System/Info

    url = build_url(config, "/System/Info")

    case Req.get(url, headers: headers(config)) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, Error.auth("HTTP #{status}")}

      {:ok, %{status: status}} ->
        {:error, Error.unexpected("Connection failed: HTTP #{status}")}

      {:error, exception} ->
        {:error, Error.unexpected("Connection failed: #{Exception.message(exception)}")}
    end
  end

  @impl true
  def update_library(config, _opts \\ []) do
    # Jellyfin refresh library: POST /Library/Refresh
    # We can't easily scan by path without knowing the library layout, so trigger full scan for now.

    url = build_url(config, "/Library/Refresh")

    Logger.info("Triggering Jellyfin library scan", server: config.name)

    case Req.post(url, headers: headers(config)) do
      # 204 No Content is success
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, Error.auth("HTTP #{status}")}

      {:ok, %{status: status}} ->
        {:error, Error.unexpected("Scan failed: HTTP #{status}")}

      {:error, exception} ->
        {:error, Error.unexpected("Scan failed: #{Exception.message(exception)}")}
    end
  end

  # ── Watched Sync API ──────────────────────────────────────────────

  @page_size 200
  @ticks_per_second 10_000_000

  @doc """
  Lists the server's user accounts.

  Returns `{:ok, [%{id: String.t(), name: String.t()}]}`.
  """
  def list_users(config) do
    case Req.get(build_url(config, "/Users"), headers: headers(config)) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Enum.map(List.wrap(body), fn user -> %{id: user["Id"], name: user["Name"]} end)}

      other ->
        classify(other)
    end
  end

  @doc """
  Lists every movie and episode, paging until the server reports no more.

  ## Options

    * `:user_id` - when set, scopes the query to that user and requests
      `UserData`. Under API-key auth Jellyfin omits `UserData` entirely unless
      both `userId` and `enableUserData` are sent, which returns a successful
      response carrying no watch state at all.
    * `:page_size` - items per request (default #{@page_size})
  """
  def list_items(config, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @page_size)
    user_id = Keyword.get(opts, :user_id)

    fetch_items_page(config, user_id, page_size, 0, [])
  end

  @doc """
  Marks an item played for a user.
  """
  def mark_played(config, user_id, item_id) do
    played_request(:post, config, user_id, item_id)
  end

  @doc """
  Marks an item unplayed for a user.
  """
  def mark_unplayed(config, user_id, item_id) do
    played_request(:delete, config, user_id, item_id)
  end

  @doc """
  Writes a resume position, in seconds, for a user.

  Servers without `/UserItems/{id}/UserData` answer 404. That endpoint arrived
  in 10.9, and an operator cannot be asked to match a Jellyfin version, so a
  404 degrades to watched-only rather than failing the run.
  """
  def set_position(config, user_id, item_id, seconds) when is_integer(seconds) do
    url = build_url(config, "/UserItems/#{item_id}/UserData")

    case Req.post(url,
           headers: headers(config),
           params: [userId: user_id],
           json: %{"PlaybackPositionTicks" => seconds * @ticks_per_second}
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        Logger.debug("Jellyfin has no UserData endpoint; skipping resume position")
        :ok

      other ->
        classify(other)
    end
  end

  # `total` only bounds the loop when the server actually reports an integer
  # count. Without that, or when the current page came back short of
  # `page_size`, a short/empty page is the sole signal that pagination is
  # done; relying on a `TotalRecordCount` that overstates the real item count
  # (or is missing/null and defaults to the running total) would otherwise
  # either stop after the first page or never satisfy the `>=` check.
  defp fetch_items_page(config, user_id, page_size, start_index, acc) do
    params =
      [
        recursive: true,
        includeItemTypes: "Movie,Episode",
        fields: "ProviderIds",
        startIndex: start_index,
        limit: page_size
      ]
      |> maybe_put_user(user_id)

    case Req.get(build_url(config, "/Items"), headers: headers(config), params: params) do
      {:ok, %{status: 200, body: body}} ->
        items = List.wrap(body["Items"])
        # Accumulated in reverse and flipped once at the end. Appending with
        # `++` walks the whole accumulator on every page, so a large library
        # pages in quadratic time. `last_page?/4` only reads `acc` through
        # `length/1`, so the ordering here does not affect the stop condition.
        acc = Enum.reverse(items, acc)
        total = body["TotalRecordCount"]

        if last_page?(items, acc, total, page_size) do
          {:ok, Enum.reverse(acc)}
        else
          fetch_items_page(config, user_id, page_size, start_index + length(items), acc)
        end

      other ->
        classify(other)
    end
  end

  defp last_page?([], _acc, _total, _page_size), do: true

  defp last_page?(items, _acc, _total, page_size) when length(items) < page_size, do: true

  defp last_page?(_items, acc, total, _page_size) when is_integer(total),
    do: length(acc) >= total

  defp last_page?(_items, _acc, _total, _page_size), do: false

  defp maybe_put_user(params, nil), do: params

  defp maybe_put_user(params, user_id) do
    params ++ [userId: user_id, enableUserData: true]
  end

  # `/Users/{uid}/PlayedItems/{id}` is obsolete but still present on older
  # servers, so a 404 from the current route retries the legacy one.
  defp played_request(method, config, user_id, item_id) do
    current = build_url(config, "/UserPlayedItems/#{item_id}")
    legacy = build_url(config, "/Users/#{user_id}/PlayedItems/#{item_id}")

    case played_call(method, current, config, userId: user_id) do
      {:ok, %{status: 404}} -> played_call(method, legacy, config, []) |> classify_played()
      other -> classify_played(other)
    end
  end

  defp played_call(:post, url, config, params),
    do: Req.post(url, headers: headers(config), params: params)

  defp played_call(:delete, url, config, params),
    do: Req.delete(url, headers: headers(config), params: params)

  defp classify_played({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify_played(other), do: classify(other)

  defp classify({:ok, %{status: status}}) when status in [401, 403],
    do: {:error, Error.auth("HTTP #{status}")}

  defp classify({:ok, %{status: status}}),
    do: {:error, Error.unexpected("HTTP #{status}")}

  defp classify({:error, %Req.TransportError{} = e}),
    do: {:error, Error.unreachable(Exception.message(e))}

  defp classify({:error, exception}),
    do: {:error, Error.unexpected(Exception.message(exception))}

  # ── Private Helpers ────────────────────────────────────────────────

  defp build_url(config, path) do
    base = String.trim_trailing(config.url, "/")
    "#{base}#{path}"
  end

  defp headers(config) do
    [
      {"X-Emby-Token", config.token},
      {"Authorization", "MediaBrowser Token=\"#{config.token}\""},
      {"Accept", "application/json"}
    ]
  end
end
