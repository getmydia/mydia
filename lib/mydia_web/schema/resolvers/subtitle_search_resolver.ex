defmodule MydiaWeb.Schema.Resolvers.SubtitleSearchResolver do
  @moduledoc """
  Resolvers for player-initiated subtitle search and download.
  """

  require Logger

  alias Mydia.Accounts.User
  alias Mydia.Subtitles
  alias Mydia.Subtitles.Candidate
  alias Mydia.Subtitles.Extractor

  @doc """
  Searches every enabled provider for subtitles matching a media file.
  """
  def search(_parent, %{media_file_id: media_file_id, languages: languages}, %{
        context: %{current_user: %User{}}
      }) do
    case Subtitles.search_candidates(media_file_id, Enum.join(languages, ",")) do
      {:ok, %{results: results, providers: providers}} ->
        {:ok,
         %{
           results: Enum.map(results, &to_candidate(&1, media_file_id)),
           providers: providers
         }}

      {:error, :media_file_not_found} ->
        {:error, "Media file not found"}

      {:error, :insufficient_search_criteria} ->
        {:error, "This file has no hash or metadata IDs to search with"}

      {:error, reason} ->
        Logger.error("Subtitle search failed: #{inspect(reason)}")
        {:error, "Subtitle search failed"}
    end
  end

  def search(_parent, _args, _info), do: {:error, "Not authenticated"}

  @doc """
  Downloads a candidate and returns the resulting subtitle track.
  """
  def download(_parent, %{media_file_id: media_file_id, token: token}, %{
        context: %{current_user: %User{}}
      }) do
    with {:ok, payload} <- Candidate.verify(token, media_file_id),
         {:ok, subtitle} <- Subtitles.download_subtitle(to_subtitle_info(payload), media_file_id) do
      track =
        media_file_id
        |> Extractor.list_external_subtitle_tracks()
        |> Enum.find(&(&1.track_id == subtitle.id))

      case track do
        nil -> {:error, "Subtitle downloaded but could not be listed"}
        track -> {:ok, Map.put(track, :_media_file_id, media_file_id)}
      end
    else
      {:error, :expired} ->
        {:error, "These search results expired. Search again."}

      {:error, :media_file_mismatch} ->
        {:error, "This result is not valid for this file. Search again."}

      {:error, :invalid} ->
        {:error, "This result is not valid. Search again."}

      {:error, reason} ->
        Logger.error("Subtitle download failed: #{inspect(reason)}")
        {:error, "Subtitle download failed"}
    end
  end

  def download(_parent, _args, _info), do: {:error, "Not authenticated"}

  ## Private

  defp to_candidate(result, media_file_id) do
    # Providers often leave :format nil and put the real extension on the file
    # name. Normalize before signing so download validation accepts the token.
    normalized = Map.put(result, :format, normalize_format(result))

    %{
      token: Candidate.sign(media_file_id, normalized),
      language: result.language,
      release_name: Map.get(result, :file_name),
      format: normalized.format,
      rating: Map.get(result, :rating),
      download_count: Map.get(result, :download_count),
      hearing_impaired: Map.get(result, :hearing_impaired) || false,
      hash_match: Map.get(result, :moviehash_match) || false,
      score: Map.get(result, :score) || 0,
      provider_name: Map.get(result, :provider_name) || "Unknown"
    }
  end

  # Providers often leave :format nil and put the real extension on the file name.
  defp normalize_format(%{format: format}) when is_binary(format) and format != "", do: format

  defp normalize_format(%{file_name: name}) when is_binary(name) do
    case name |> Path.extname() |> String.trim_leading(".") |> String.downcase() do
      "" -> "srt"
      ext -> ext
    end
  end

  defp normalize_format(_result), do: "srt"

  defp to_subtitle_info(payload) do
    %{
      file_id: payload.file_id,
      language: payload.language,
      format: payload.format,
      subtitle_hash: payload.subtitle_hash,
      rating: Map.get(payload, :rating),
      download_count: Map.get(payload, :download_count),
      hearing_impaired: Map.get(payload, :hearing_impaired) || false
    }
  end
end
