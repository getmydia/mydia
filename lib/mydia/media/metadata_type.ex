defmodule Mydia.Media.MetadataType do
  @moduledoc """
  Custom Ecto type for MediaMetadata that provides full type safety.

  This type automatically converts between MediaMetadata structs and plain maps
  during database operations, ensuring that all metadata fields are properly typed
  throughout the application.

  ## Benefits
  - Compile-time safety when accessing metadata fields
  - Automatic struct conversion on load/dump
  - Proper handling of nested structs (CastMember, CrewMember, SeasonInfo)
  - Prevents silent nil returns from typos in field names

  ## Usage
  In your schema:

      schema "media_items" do
        field :metadata, Mydia.Media.MetadataType
      end

  When you load a media item from the database, metadata will automatically
  be a %MediaMetadata{} struct instead of a plain map.
  """

  use Ecto.Type

  alias Mydia.Metadata.Structs.{MediaMetadata, CastMember, CrewMember, SeasonInfo, Video}

  @doc """
  Returns the underlying database type (:string for text columns).
  """
  def type, do: :string

  @doc """
  Casts the given value to a MediaMetadata struct.

  Accepts:
  - MediaMetadata struct (returns as-is)
  - Map with string keys (converts to MediaMetadata)
  - Map with atom keys (converts to MediaMetadata)
  - nil (returns nil)
  """
  def cast(%MediaMetadata{} = metadata), do: {:ok, metadata}
  def cast(nil), do: {:ok, nil}

  def cast(data) when is_map(data) do
    {:ok, map_to_struct(data)}
  rescue
    e -> {:error, "Failed to cast to MediaMetadata: #{inspect(e)}"}
  end

  def cast(_), do: :error

  @doc """
  Loads data from the database (JSON string) and converts to MediaMetadata struct.
  """
  def load(nil), do: {:ok, nil}
  def load(""), do: {:ok, nil}

  def load(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> {:ok, map_to_struct(map)}
      {:ok, _} -> :error
      {:error, _} -> :error
    end
  rescue
    e -> {:error, "Failed to load MediaMetadata: #{inspect(e)}"}
  end

  # Handle case where data is already a map (some adapters may do this)
  def load(data) when is_map(data) do
    {:ok, map_to_struct(data)}
  rescue
    e -> {:error, "Failed to load MediaMetadata: #{inspect(e)}"}
  end

  def load(_), do: :error

  @doc """
  Dumps a MediaMetadata struct to a JSON string for database storage.
  """
  def dump(%MediaMetadata{} = metadata) do
    {:ok, Jason.encode!(struct_to_map(metadata))}
  end

  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  # Converts a plain map (from DB) to MediaMetadata struct
  defp map_to_struct(data) when is_map(data) do
    # Convert string keys to atom keys if needed
    data = atomize_keys(data)

    # Extract required fields with fallback values
    provider_id = data[:provider_id] || to_string(data[:id] || "")
    provider = atomize_value(data[:provider] || :metadata_relay)
    media_type = atomize_value(data[:media_type] || :movie)

    %MediaMetadata{
      provider_id: provider_id,
      provider: provider,
      media_type: media_type,
      id: data[:id],
      title: data[:title],
      original_title: data[:original_title],
      year: data[:year],
      release_date: parse_date(data[:release_date]),
      overview: data[:overview],
      tagline: data[:tagline],
      runtime: data[:runtime],
      status: data[:status],
      content_rating: data[:content_rating],
      genres: data[:genres],
      poster_path: data[:poster_path],
      backdrop_path: data[:backdrop_path],
      popularity: data[:popularity],
      vote_average: data[:vote_average],
      vote_count: data[:vote_count],
      imdb_id: data[:imdb_id],
      external_ids: parse_external_ids(data[:external_ids]),
      production_companies: data[:production_companies],
      production_countries: data[:production_countries],
      spoken_languages: data[:spoken_languages],
      homepage: data[:homepage],
      cast: parse_cast_list(data[:cast]),
      crew: parse_crew_list(data[:crew]),
      alternative_titles: data[:alternative_titles],
      videos: parse_videos_list(data[:videos]),
      recommended_tmdb_ids: data[:recommended_tmdb_ids],
      origin_country: data[:origin_country],
      original_language: data[:original_language],
      collection_id: data[:collection_id],
      collection_name: data[:collection_name],
      number_of_seasons: data[:number_of_seasons],
      number_of_episodes: data[:number_of_episodes],
      episode_run_time: data[:episode_run_time],
      first_air_date: parse_date(data[:first_air_date]),
      last_air_date: parse_date(data[:last_air_date]),
      in_production: data[:in_production],
      seasons: parse_seasons_list(data[:seasons])
    }
  end

  # Converts MediaMetadata struct to plain map for DB storage
  defp struct_to_map(%MediaMetadata{} = metadata) do
    metadata
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, convert_value_to_map(v)} end)
    |> Map.new()
  end

  # Convert nested structs to maps
  defp convert_value_to_map(%Date{} = date), do: date
  defp convert_value_to_map(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp convert_value_to_map(%CastMember{} = member), do: Map.from_struct(member)
  defp convert_value_to_map(%CrewMember{} = member), do: Map.from_struct(member)
  defp convert_value_to_map(%SeasonInfo{} = season), do: Map.from_struct(season)

  defp convert_value_to_map(%Video{} = video) do
    video
    |> Map.from_struct()
    |> Map.update(:published_at, nil, &convert_value_to_map/1)
  end

  defp convert_value_to_map(list) when is_list(list), do: Enum.map(list, &convert_value_to_map/1)
  defp convert_value_to_map(value), do: value

  # Parse cast list from maps to CastMember structs
  defp parse_cast_list(nil), do: nil
  defp parse_cast_list([]), do: []

  defp parse_cast_list(cast) when is_list(cast) do
    Enum.map(cast, fn member ->
      member = atomize_keys(member)

      %CastMember{
        name: member.name || member[:name],
        character: member[:character],
        order: member[:order],
        profile_path: member[:profile_path]
      }
    end)
  end

  # Parse crew list from maps to CrewMember structs
  defp parse_crew_list(nil), do: nil
  defp parse_crew_list([]), do: []

  defp parse_crew_list(crew) when is_list(crew) do
    Enum.map(crew, fn member ->
      member = atomize_keys(member)

      %CrewMember{
        name: member.name || member[:name],
        job: member.job || member[:job],
        department: member[:department],
        profile_path: member[:profile_path]
      }
    end)
  end

  # Parse seasons list from maps to SeasonInfo structs
  defp parse_seasons_list(nil), do: nil
  defp parse_seasons_list([]), do: []

  defp parse_seasons_list(seasons) when is_list(seasons) do
    Enum.map(seasons, fn season ->
      season = atomize_keys(season)

      %SeasonInfo{
        season_number: season.season_number || season[:season_number],
        name: season[:name],
        overview: season[:overview],
        air_date: season[:air_date],
        episode_count: season[:episode_count],
        poster_path: season[:poster_path],
        tvdb_season_id: season[:tvdb_season_id]
      }
    end)
  end

  # Parse videos list from maps to Video structs
  defp parse_videos_list(nil), do: nil
  defp parse_videos_list([]), do: []

  defp parse_videos_list(videos) when is_list(videos) do
    Enum.map(videos, fn video ->
      video = atomize_keys(video)

      %Video{
        id: video[:id],
        key: video[:key],
        name: video[:name],
        site: video[:site],
        type: video[:type],
        official: video[:official],
        published_at: parse_datetime(video[:published_at])
      }
    end)
  end

  # `external_ids` is nil when the metadata was written before cross-provider
  # id storage existed, or when the provider response carried no such block.
  # `Mydia.Jobs.MetadataBackfill` reads that nil as "never checked" versus a
  # populated map as "checked, here's what we found". This must round-trip
  # through the database exactly as it was written, nil or not.
  #
  # The coercions mirror `Mydia.Metadata.Structs.MediaMetadata`'s own parser:
  # these ids are handed straight to `Media.get_media_item_by_tmdb/1` and
  # friends, which query :integer columns and raise `Ecto.Query.CastError` on a
  # string rather than returning nil. Nothing writes string ids here today, but
  # a metadata map built by hand would, and the two parsers staying identical
  # is what keeps that true.
  defp parse_external_ids(nil), do: nil

  defp parse_external_ids(ids) when is_map(ids) do
    %{
      tmdb: parse_external_integer(external_id_value(ids, :tmdb)),
      tvdb: parse_external_integer(external_id_value(ids, :tvdb)),
      imdb: parse_external_string(external_id_value(ids, :imdb))
    }
  end

  defp parse_external_ids(_), do: nil

  # Read the three keys directly in both forms rather than atomizing the map.
  # It arrives from persisted JSON, so its keys are whatever was written, and
  # `atomize_keys/1` falls back to `String.to_atom/1` for a key it has never
  # seen -- one permanently held VM atom per distinct key. Nothing else in this
  # map is meaningful.
  defp external_id_value(ids, key) do
    Map.get(ids, key) || Map.get(ids, Atom.to_string(key))
  end

  defp parse_external_integer(id) when is_integer(id) and id > 0, do: id

  defp parse_external_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_external_integer(_), do: nil

  defp parse_external_string(id) when is_binary(id) and id != "", do: id
  defp parse_external_string(_), do: nil

  # Parse date strings to Date structs
  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = date), do: date

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  # Parse datetime strings to DateTime structs (for Video published_at)
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # Convert string keys to atom keys for easier access
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        # Try to convert to existing atom, fall back to creating new atom if needed
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> String.to_atom(k)
          end

        {atom_key, v}

      {k, v} ->
        {k, v}
    end)
  end

  # Convert string values to atoms for enums
  defp atomize_value(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize_value(value) when is_atom(value), do: value
  defp atomize_value(value), do: value
end
