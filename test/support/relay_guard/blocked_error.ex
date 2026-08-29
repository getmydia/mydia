defmodule Mydia.RelayGuard.BlockedError do
  @moduledoc """
  The value `Mydia.RelayGuard` returns when it refuses an outbound request.

  Deliberately not a `Req.TransportError` or `Req.HTTPError`. Those are the two
  shapes `Req.Steps.transient?/1` retries, and
  `Mydia.Metadata.Provider.HTTP.new_request/1` sets `retry: :transient,
  max_retries: 3`. A retried refusal would burn about 6.8 seconds of backoff and
  blow the 5s `render_async` budget instead of failing immediately.
  """

  defexception [:url]

  @impl true
  def message(%__MODULE__{url: url}) do
    """
    Mydia.RelayGuard refused an outbound HTTP request to #{url.host}:

        #{URI.to_string(url)}

    Tests must not reach the network. Warm the metadata cache with
    Mydia.MetadataCacheHelpers (warm_recommendations_cache/3,
    warm_movie_details_cache/1, warm_collection_cache/2, warm_trending_cache/2,
    warm_genre_cache/2, warm_movie_search_cache/3), or serve the response from
    Bypass on localhost.
    """
  end
end
