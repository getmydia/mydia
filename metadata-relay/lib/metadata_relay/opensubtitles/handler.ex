defmodule MetadataRelay.OpenSubtitles.Handler do
  @moduledoc """
  Request handlers for OpenSubtitles.com subtitle API endpoints.

  This module provides the business logic layer between the router and the
  OpenSubtitles client. It transforms provider-specific responses into a
  standardized format that abstracts away the underlying provider implementation.

  This allows Mydia instances to work with a consistent API regardless of which
  subtitle provider is being used (OpenSubtitles, Podnapisi, etc.).
  """

  require Logger
  alias MetadataRelay.OpenSubtitles.Client

  @doc """
  Search for subtitles based on various criteria.

  ## Parameters

  - `imdb_id` - IMDB identifier (e.g., "123456" without "tt" prefix)
  - `tmdb_id` - TMDB identifier
  - `file_hash` - Video file hash (moviehash) for precise matching
  - `file_size` - File size in bytes (required when using file_hash)
  - `languages` - Comma-separated language codes (e.g., "en,es,fr")
  - `query` - Text search query (less accurate than ID-based search)
  - `media_type` - "movie" or "episode" (optional)

  ## Returns

  Returns `{:ok, results}` with standardized subtitle metadata, or `{:error, reason}`.

  ## Examples

      # Search by IMDB ID and language
      search(%{imdb_id: "816692", languages: "en"})

      # Search by file hash (most accurate)
      search(%{file_hash: "8e245d9679d31e12", file_size: "742086656", languages: "en"})

  """
  def search(params) do
    # Build query parameters for OpenSubtitles API
    query_params = build_search_params(params)

    Logger.debug("Searching OpenSubtitles with params: #{inspect(query_params)}")

    case Client.get("/subtitles", params: query_params) do
      {:ok, %{"data" => subtitles}} when is_list(subtitles) ->
        # Transform OpenSubtitles response to standardized format
        transformed = Enum.map(subtitles, &transform_subtitle/1)
        {:ok, %{"subtitles" => transformed}}

      {:ok, response} ->
        # Unexpected response format
        Logger.warning("Unexpected OpenSubtitles search response: #{inspect(response)}")
        {:ok, %{"subtitles" => []}}

      {:error, {:rate_limited, retry_after, _body}} ->
        {:error, {:rate_limited, retry_after}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get a temporary download URL for a subtitle file.

  ## Parameters

  - `file_id` - The OpenSubtitles file ID from search results

  ## Returns

  Returns `{:ok, download_info}` with download URL and metadata, or `{:error, reason}`.

  The download URL is temporary and will expire after a short period (typically 24 hours).
  """
  def get_download_url(file_id) do
    Logger.debug("Requesting download URL for file_id: #{file_id}")

    # Convert file_id to integer if it's a string
    file_id_int =
      case Integer.parse(to_string(file_id)) do
        {int, _} -> int
        :error -> file_id
      end

    case Client.post("/download", %{file_id: file_id_int}) do
      {:ok,
       %{
         "link" => link,
         "file_name" => file_name,
         "requests" => requests,
         "remaining" => remaining
       }} ->
        {:ok,
         %{
           "download_url" => link,
           "file_name" => file_name,
           "requests_used" => requests,
           "requests_remaining" => remaining
         }}

      {:ok, response} ->
        # Handle other response formats
        Logger.warning("Unexpected download response: #{inspect(response)}")
        {:error, {:unexpected_response, response}}

      {:error, {:rate_limited, retry_after, _body}} ->
        {:error, {:rate_limited, retry_after}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Functions

  defp build_search_params(params) do
    params
    |> Enum.reduce([], fn {key, value}, acc ->
      case {key, value} do
        # Skip nil values
        {_, nil} -> acc
        {_, ""} -> acc
        # Map our parameter names to OpenSubtitles API parameter names
        {:file_hash, hash} -> [{:moviehash, hash} | acc]
        {:file_size, size} -> [{:moviebytesize, size} | acc]
        {:media_type, "movie"} -> [{:type, "movie"} | acc]
        {:media_type, "episode"} -> [{:type, "episode"} | acc]
        # Pass through parameters that match OpenSubtitles API
        {:imdb_id, id} -> [{:imdb_id, id} | acc]
        {:tmdb_id, id} -> [{:tmdb_id, id} | acc]
        {:languages, langs} -> [{:languages, langs} | acc]
        {:query, q} -> [{:query, q} | acc]
        # Ignore unknown parameters
        _ -> acc
      end
    end)
  end

  defp transform_subtitle(subtitle_data) do
    # Extract file information
    file = subtitle_data["attributes"] || %{}
    feature = file["feature_details"] || %{}

    # Build standardized subtitle entry
    %{
      "id" => get_file_id(subtitle_data),
      "language" => file["language"] || "unknown",
      "format" => file["format"] || "srt",
      "rating" => file["ratings"] || 0.0,
      "download_count" => file["download_count"] || 0,
      "release" => file["release"] || "",
      "uploader" => file["uploader"] || %{} |> Map.get("name", "unknown"),
      "hearing_impaired" => file["hearing_impaired"] || false,
      "foreign_parts_only" => file["foreign_parts_only"] || false,
      "moviehash_match" => file["moviehash_match"] || false,
      # Feature details (movie/show info)
      "feature_type" => feature["feature_type"],
      "title" => feature["title"],
      "year" => feature["year"],
      "imdb_id" => feature["imdb_id"],
      "tmdb_id" => feature["tmdb_id"]
    }
  end

  defp get_file_id(subtitle_data) do
    # Try to get file_id from different possible locations in the response
    cond do
      is_map(subtitle_data["attributes"]) and subtitle_data["attributes"]["files"] ->
        # Files is a list, get the first file's file_id
        case subtitle_data["attributes"]["files"] do
          [%{"file_id" => id} | _] -> id
          _ -> subtitle_data["id"]
        end

      true ->
        # Fall back to the main subtitle ID
        subtitle_data["id"]
    end
  end
end
