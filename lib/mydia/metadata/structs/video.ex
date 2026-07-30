defmodule Mydia.Metadata.Structs.Video do
  @moduledoc """
  Represents a video (trailer, teaser, featurette) from TMDB metadata.

  This struct provides compile-time safety for video information from TMDB API
  responses. Videos are typically trailers hosted on YouTube or Vimeo.

  ## YouTube Embed URL

  To embed a YouTube video, use the key to construct the URL:

      https://www.youtube.com/embed/{key}

  For example, a video with key "abc123" would embed as:

      https://www.youtube.com/embed/abc123
  """

  @derive Jason.Encoder
  @enforce_keys [:key, :site]

  defstruct [
    :id,
    :key,
    :name,
    :site,
    :type,
    :official,
    :published_at
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t(),
          name: String.t() | nil,
          site: String.t(),
          type: String.t() | nil,
          official: boolean() | nil,
          published_at: DateTime.t() | nil
        }

  # Hosts whose /embed/KEY, /v/KEY, /shorts/KEY paths or ?v=KEY query carry the key.
  @youtube_hosts ~w(youtube.com www.youtube.com m.youtube.com music.youtube.com)
  # Hosts whose entire path is the key.
  @youtube_short_hosts ~w(youtu.be www.youtu.be)

  @doc """
  Creates a new Video struct from a map or keyword list.

  ## Examples

      iex> new(key: "dQw4w9WgXcQ", site: "YouTube", name: "Official Trailer", type: "Trailer")
      %Video{
        key: "dQw4w9WgXcQ",
        site: "YouTube",
        name: "Official Trailer",
        type: "Trailer",
        official: nil,
        published_at: nil
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Creates a Video struct from a raw TMDB API response map.

  ## Examples

      iex> from_api_response(%{
      ...>   "id" => "123abc",
      ...>   "key" => "dQw4w9WgXcQ",
      ...>   "name" => "Official Trailer",
      ...>   "site" => "YouTube",
      ...>   "type" => "Trailer",
      ...>   "official" => true,
      ...>   "published_at" => "2024-01-15T14:00:00.000Z"
      ...> })
      %Video{
        id: "123abc",
        key: "dQw4w9WgXcQ",
        name: "Official Trailer",
        site: "YouTube",
        type: "Trailer",
        official: true,
        published_at: ~U[2024-01-15 14:00:00Z]
      }
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      key: data["key"],
      name: data["name"],
      site: data["site"],
      type: data["type"],
      official: data["official"],
      published_at: parse_datetime(data["published_at"])
    }
  end

  @doc """
  Returns the YouTube embed URL for this video.

  Returns nil if the video is not hosted on YouTube.

  ## Examples

      iex> video = %Video{key: "dQw4w9WgXcQ", site: "YouTube"}
      iex> youtube_embed_url(video)
      "https://www.youtube.com/embed/dQw4w9WgXcQ"

      iex> video = %Video{key: "abc123", site: "Vimeo"}
      iex> youtube_embed_url(video)
      nil
  """
  def youtube_embed_url(%__MODULE__{site: "YouTube", key: key}) when is_binary(key) do
    "https://www.youtube.com/embed/#{key}"
  end

  def youtube_embed_url(_), do: nil

  @doc """
  Builds a Video struct from a raw TVDB trailer map.

  TVDB trailer entries from `/series/{id}/extended` look like:

      %{"id" => 204863, "language" => "eng", "name" => "Trailer",
        "runtime" => 0, "url" => "https://www.youtube.com/watch?v=M1bhOaLV4FU"}

  They carry no `type`, `official`, or `published_at`, so `type` is set to
  "Trailer" to keep these structs consistent with TMDB-derived ones.

  Returns `:error` for anything that is not a recognisable YouTube URL, since
  `youtube_embed_url/1` is the only embed helper the UI has.

  ## Examples

      iex> from_tvdb_trailer(%{"id" => 1, "name" => "Trailer", "url" => "https://youtu.be/abc123"})
      {:ok, %Video{id: "1", key: "abc123", name: "Trailer", site: "YouTube", type: "Trailer"}}

      iex> from_tvdb_trailer(%{"url" => "https://vimeo.com/123"})
      :error
  """
  @spec from_tvdb_trailer(map()) :: {:ok, t()} | :error
  def from_tvdb_trailer(%{"url" => url} = trailer) when is_binary(url) do
    case youtube_key(url) do
      nil ->
        :error

      key ->
        {:ok,
         %__MODULE__{
           id: trailer_id(trailer["id"]),
           key: key,
           name: trailer["name"],
           site: "YouTube",
           type: "Trailer"
         }}
    end
  end

  def from_tvdb_trailer(_), do: :error

  @doc """
  Builds Video structs from a raw TVDB `trailers` list.

  Entries whose URL cannot be parsed as a YouTube link are dropped. Entries
  whose `language` matches one of `preferred_codes` — an ordered list of TVDB
  language codes such as `["eng", "en"]` — sort ahead of the rest; order within
  a group is preserved. Unmatched languages are kept, not dropped, because a
  trailer in the wrong language still beats no trailer.
  """
  @spec from_tvdb_trailers(list() | nil, [String.t()]) :: [t()]
  def from_tvdb_trailers(trailers, preferred_codes \\ [])

  def from_tvdb_trailers(trailers, preferred_codes) when is_list(trailers) do
    trailers
    |> Enum.flat_map(fn trailer ->
      case from_tvdb_trailer(trailer) do
        {:ok, video} -> [{trailer["language"], video}]
        :error -> []
      end
    end)
    |> Enum.sort_by(fn {language, _video} -> language_rank(language, preferred_codes) end)
    |> Enum.map(fn {_language, video} -> video end)
  end

  def from_tvdb_trailers(_trailers, _preferred_codes), do: []

  defp trailer_id(nil), do: nil
  defp trailer_id(id), do: to_string(id)

  # Enum.sort_by/2 is stable, so equal ranks keep their input order.
  defp language_rank(language, preferred_codes) do
    case Enum.find_index(preferred_codes, &(&1 == language)) do
      nil -> length(preferred_codes)
      index -> index
    end
  end

  defp youtube_key(url) do
    case URI.parse(url) do
      %URI{host: host, path: path, query: query} when host in @youtube_hosts ->
        key_from_embed_path(path) || key_from_query(query)

      %URI{host: host, path: path} when host in @youtube_short_hosts ->
        key_from_short_path(path)

      _ ->
        nil
    end
  end

  defp key_from_embed_path(nil), do: nil

  defp key_from_embed_path(path) do
    case String.split(path, "/", trim: true) do
      ["embed", key | _] -> presence(key)
      ["v", key | _] -> presence(key)
      ["shorts", key | _] -> presence(key)
      _ -> nil
    end
  end

  defp key_from_short_path(nil), do: nil

  defp key_from_short_path(path) do
    case String.split(path, "/", trim: true) do
      [key] -> presence(key)
      _ -> nil
    end
  end

  defp key_from_query(nil), do: nil

  defp key_from_query(query) do
    query |> URI.decode_query() |> Map.get("v") |> presence()
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end
end
