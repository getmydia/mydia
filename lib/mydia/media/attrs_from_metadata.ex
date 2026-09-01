defmodule Mydia.Media.AttrsFromMetadata do
  @moduledoc """
  Builds media item attrs from provider metadata.

  Lifted out of `MydiaWeb.SearchLive.Index`, where these were private
  functions inside a large LiveView with no way to test them: its own
  add-to-library test is skipped for want of metadata mocking. They also read
  only `monitor_by_default` and set neither quality profile nor library path,
  so a title created by grabbing a release came out configured differently
  from the same title added through Discover. Both now go through
  `Mydia.Media.AddDefaults`.
  """

  alias Mydia.Media.AddDefaults

  @doc """
  Builds attrs from a parsed release name plus its resolved metadata.

  `opts` accepts `:defaults` to inject an `%AddDefaults{}` in tests.
  """
  @spec from_parsed(map(), map(), keyword()) :: map()
  def from_parsed(parsed, metadata, opts \\ []) do
    media_type = parsed_media_type(parsed)
    defaults = defaults_for(media_type, opts)

    base = %{
      type: type_string(media_type),
      title: metadata.title || parsed.title,
      original_title: Map.get(metadata, :original_title),
      year: year_from(metadata) || Map.get(parsed, :year),
      metadata: metadata,
      monitored: defaults.monitored,
      quality_profile_id: defaults.quality_profile_id,
      library_path_id: defaults.library_path_id
    }

    put_provider_id(base, media_type, metadata)
  end

  @doc """
  Builds attrs from metadata alone, for a title with no parsed release.

  `opts` accepts `:defaults` to inject an `%AddDefaults{}` in tests.
  """
  @spec from_metadata(map(), :movie | :tv_show, keyword()) :: map()
  def from_metadata(metadata, media_type, opts \\ []) do
    defaults = defaults_for(media_type, opts)

    base = %{
      type: type_string(media_type),
      title: metadata.title,
      original_title: Map.get(metadata, :original_title),
      year: year_from(metadata),
      metadata: metadata,
      monitored: defaults.monitored,
      quality_profile_id: defaults.quality_profile_id,
      library_path_id: defaults.library_path_id
    }

    put_provider_id(base, media_type, metadata)
  end

  defp defaults_for(media_type, opts) do
    Keyword.get_lazy(opts, :defaults, fn -> AddDefaults.resolve(nil, media_type) end)
  end

  defp parsed_media_type(%{type: :tv_show}), do: :tv_show
  defp parsed_media_type(_), do: :movie

  defp type_string(:tv_show), do: "tv_show"
  defp type_string(_), do: "movie"

  # A TV show sourced from TVDB is keyed by tvdb_id; everything else by
  # tmdb_id. Carried over from SearchLive unchanged.
  defp put_provider_id(base, :tv_show, %{provider: :tvdb} = metadata),
    do: Map.put(base, :tvdb_id, metadata.provider_id)

  defp put_provider_id(base, _media_type, metadata),
    do: Map.put(base, :tmdb_id, metadata.provider_id)

  defp year_from(metadata) do
    Map.get(metadata, :year) ||
      extract_year(Map.get(metadata, :release_date)) ||
      extract_year(Map.get(metadata, :first_air_date))
  end

  # Carried over verbatim from SearchLive's `extract_year_from_date/1`.
  # `MediaMetadata.release_date`/`first_air_date` are `Date.t() | nil`
  # (see `Mydia.Metadata.Structs.MediaMetadata`), not strings, so the `%Date{}`
  # clause is the one that actually fires in production; the binary clause is
  # kept for callers (tests, other metadata sources) that still pass strings.
  defp extract_year(%Date{} = date), do: date.year

  defp extract_year(date_string) when is_binary(date_string) do
    case String.split(date_string, "-") do
      [year_str | _] ->
        case Integer.parse(year_str) do
          {year, _} -> year
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_year(_), do: nil
end
