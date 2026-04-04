defmodule Mydia.Settings.QualityMatcher do
  @moduledoc """
  Matches and scores search results against quality profiles.

  This module provides functionality to:
  - Check if a SearchResult meets a quality profile's requirements
  - Calculate quality scores for ranking multiple matches
  - Determine if a result would be an upgrade for existing media
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Settings.QualityProfile

  @doc """
  Checks if a search result matches a quality profile's requirements.

  Returns `{:ok, score}` if the result matches, where score is 0.0-100.0.
  Returns `{:error, reason}` if the result doesn't match.

  Uses the quality_standards scoring system from QualityProfile.score_media_file/2.
  Results with violations or scores below the minimum threshold are rejected.

  ## Examples

      iex> result = %SearchResult{...}
      iex> profile = %QualityProfile{...}
      iex> QualityMatcher.matches?(result, profile)
      {:ok, 85.5}

      iex> QualityMatcher.matches?(bad_result, profile)
      {:error, :quality_score_too_low}
  """
  @spec matches?(SearchResult.t(), QualityProfile.t()) ::
          {:ok, float()} | {:error, atom() | String.t()}
  def matches?(%SearchResult{} = result, %QualityProfile{} = profile) do
    # Convert SearchResult to media attributes map for scoring
    media_attrs = search_result_to_media_attrs(result)

    # Calculate score using quality_standards
    score_result = QualityProfile.score_media_file(profile, media_attrs)
    min_score = min_quality_score()

    # Check for violations
    case score_result do
      %{violations: [violation | _]} ->
        {:error, violation}

      %{score: score} when score < min_score ->
        {:error, :quality_score_too_low}

      %{score: score} ->
        # Also check legacy qualities field for backward compatibility
        with :ok <- check_quality_allowed(result, profile) do
          {:ok, score}
        end
    end
  end

  @doc """
  Calculates a quality score for a search result against a profile.

  Returns a score from 0.0-100.0, where higher is better.

  Uses the quality_standards scoring system from QualityProfile.score_media_file/2
  which considers video codec, audio codec, resolution, source, bitrates, file size,
  and HDR format preferences.

  ## Examples

      iex> result = %SearchResult{...}
      iex> profile = %QualityProfile{...}
      iex> QualityMatcher.calculate_score(result, profile)
      85.5
  """
  @spec calculate_score(SearchResult.t(), QualityProfile.t()) :: float()
  def calculate_score(%SearchResult{} = result, %QualityProfile{} = profile) do
    # Convert SearchResult to media attributes map for scoring
    media_attrs = search_result_to_media_attrs(result)

    # Calculate score using quality_standards
    %{score: score} = QualityProfile.score_media_file(profile, media_attrs)

    score
  end

  @doc """
  Checks if a result would be an upgrade over a current quality.

  Returns `true` if the result's quality is better than the current quality
  and upgrades are allowed by the profile.

  ## Examples

      iex> QualityMatcher.is_upgrade?(result, profile, "720p")
      true

      iex> QualityMatcher.is_upgrade?(result, profile, "2160p")
      false  # Already at max quality
  """
  @spec is_upgrade?(SearchResult.t(), QualityProfile.t(), String.t() | nil) :: boolean()
  def is_upgrade?(_result, %QualityProfile{upgrades_allowed: false}, _current_quality) do
    false
  end

  def is_upgrade?(%SearchResult{quality: nil}, _profile, _current_quality) do
    false
  end

  def is_upgrade?(%SearchResult{} = result, %QualityProfile{} = profile, current_quality) do
    is_upgrade?(result, profile, current_quality, nil)
  end

  @doc """
  Checks if a result would be an upgrade, with composite score comparison
  for same-resolution upgrades.

  When `current_score` is provided (a float from 0.0-100.0), same-resolution
  results are compared by composite quality score. This allows detecting upgrades
  like 1080p Telesync → 1080p BluRay where the resolution is the same but the
  overall quality is significantly better.

  The `current_score` should be computed via `QualityProfile.score_media_file/2`
  on the existing file's attributes.

  ## Examples

      iex> QualityMatcher.is_upgrade?(bluray_result, profile, "1080p", 45.0)
      true  # BluRay scores higher than the current 45.0 (e.g., telesync)

      iex> QualityMatcher.is_upgrade?(similar_result, profile, "1080p", 80.0)
      false  # Similar quality, not worth upgrading
  """
  @spec is_upgrade?(SearchResult.t(), QualityProfile.t(), String.t() | nil, float() | nil) ::
          boolean()
  def is_upgrade?(_result, %QualityProfile{upgrades_allowed: false}, _current_quality, _score) do
    false
  end

  def is_upgrade?(%SearchResult{quality: nil}, _profile, _current_quality, _score) do
    false
  end

  def is_upgrade?(
        %SearchResult{} = result,
        %QualityProfile{} = profile,
        current_quality,
        current_score
      ) do
    result_quality = result.quality.resolution

    cond do
      # No current quality means this would be the first
      is_nil(current_quality) ->
        true

      # Check if result quality is in allowed list
      result_quality not in profile.qualities ->
        false

      # If there's an upgrade_until_quality, don't exceed it
      profile.upgrade_until_quality && current_quality == profile.upgrade_until_quality ->
        false

      # Higher resolution is always an upgrade
      quality_level(result_quality) > quality_level(current_quality) ->
        true

      # Same resolution: compare composite scores if current_score is available
      quality_level(result_quality) == quality_level(current_quality) && current_score != nil ->
        candidate_score = calculate_score(result, profile)
        candidate_score > current_score

      # Same or lower resolution without score comparison
      true ->
        false
    end
  end

  ## Private Functions

  # Minimum quality score threshold (configurable via application config)
  defp min_quality_score do
    Application.get_env(:mydia, :min_quality_score, 50.0)
  end

  # Converts a SearchResult to media attributes map for QualityProfile scoring
  defp search_result_to_media_attrs(%SearchResult{} = result) do
    size_mb = result.size / (1024 * 1024)

    # Determine media type from result metadata
    media_type =
      case result.metadata do
        %{is_season_pack: true} -> :episode
        %{season_number: _} -> :episode
        _ -> :movie
      end

    # Build media attributes map for scoring
    # Note: SearchResult doesn't have all the fields that QualityProfile expects,
    # so we provide what's available and let the scoring handle missing fields
    case result.quality do
      nil ->
        %{
          file_size_mb: size_mb,
          media_type: media_type
        }

      quality ->
        %{
          video_codec: normalize_codec(quality.codec),
          audio_codec: normalize_audio_codec(quality.audio),
          resolution: quality.resolution,
          source: quality.source,
          file_size_mb: size_mb,
          media_type: media_type,
          hdr_format: if(quality.hdr, do: "hdr10", else: nil)
        }
    end
  end

  # Normalize video codec to match QualityProfile's expected format
  defp normalize_codec(nil), do: nil

  defp normalize_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> String.replace(".", "")
    |> String.replace("-", "")
  end

  # Normalize audio codec to match QualityProfile's expected format
  defp normalize_audio_codec(nil), do: nil

  defp normalize_audio_codec(codec) when is_binary(codec) do
    codec
    |> String.downcase()
    |> String.replace(".", "")
    |> String.replace("-", "")
  end

  # Check quality allowed using legacy qualities field for backward compatibility
  defp check_quality_allowed(%SearchResult{quality: nil}, _profile) do
    {:error, :quality_unknown}
  end

  defp check_quality_allowed(%SearchResult{quality: quality}, %QualityProfile{
         qualities: qualities
       }) do
    if quality.resolution in qualities do
      :ok
    else
      {:error, :quality_not_allowed}
    end
  end

  # Map quality strings to numeric levels for comparison
  defp quality_level("360p"), do: 1
  defp quality_level("480p"), do: 2
  defp quality_level("576p"), do: 3
  defp quality_level("720p"), do: 4
  defp quality_level("1080p"), do: 5
  defp quality_level("2160p"), do: 6
  defp quality_level(_), do: 0
end
