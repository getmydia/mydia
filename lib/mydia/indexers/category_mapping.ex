defmodule Mydia.Indexers.CategoryMapping do
  @moduledoc """
  Maps library types to Torznab standard categories for torrent searches.

  Torznab categories follow Newznab standard numbering:
  - 1000-1999: Console (games)
  - 2000-2999: Movies
  - 3000-3999: Audio/Music
  - 4000-4999: PC (software/games)
  - 5000-5999: TV
  - 6000-6999: XXX/Adult
  - 7000-7999: Books/Ebooks
  - 8000-8999: Other

  Both Prowlarr and Jackett use this standard category numbering.
  """

  # Torznab standard category IDs
  # Movies (2000-2999)
  @movies_parent 2000
  @movies_foreign 2010
  @movies_other 2020
  @movies_sd 2030
  @movies_hd 2040
  @movies_uhd 2045
  @movies_bluray 2050
  @movies_3d 2060
  @movies_dvd 2070

  # Audio/Music (3000-3999)
  @audio_parent 3000
  @audio_mp3 3010
  @audio_video 3020
  @audio_audiobook 3030
  @audio_lossless 3040
  @audio_other 3050
  @audio_foreign 3060

  # TV (5000-5999)
  @tv_parent 5000
  @tv_webdl 5010
  @tv_foreign 5020
  @tv_sd 5030
  @tv_hd 5040
  @tv_uhd 5045
  @tv_other 5050
  @tv_sport 5060
  @tv_anime 5070
  @tv_documentary 5080

  # Adult/XXX (6000-6999)
  @xxx_parent 6000
  @xxx_dvd 6010
  @xxx_wmv 6020
  @xxx_xvid 6030
  @xxx_x264 6040
  @xxx_uhd 6045
  @xxx_pack 6050
  @xxx_imageset 6060
  @xxx_packs 6070
  @xxx_sd 6080
  @xxx_webdl 6090

  # Books (7000-7999)
  @books_parent 7000
  @books_foreign 7010
  @books_ebook 7020
  @books_comics 7030
  @books_magazines 7040
  @books_technical 7050
  @books_other 7060
  @books_audiobook 7070

  # Other (8000-8999)
  @other_parent 8000
  @other_misc 8010
  @other_hashed 8020

  @doc """
  Returns all category IDs for the given library type.

  ## Parameters
    - library_type: One of :movies, :series, :mixed

  ## Returns
    - List of Torznab category IDs

  ## Examples

      iex> CategoryMapping.categories_for_type(:movies)
      [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070]

      iex> CategoryMapping.categories_for_type(:series)
      [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]
  """
  @spec categories_for_type(atom()) :: [integer()]
  def categories_for_type(:movies) do
    [
      @movies_parent,
      @movies_foreign,
      @movies_other,
      @movies_sd,
      @movies_hd,
      @movies_uhd,
      @movies_bluray,
      @movies_3d,
      @movies_dvd
    ]
  end

  def categories_for_type(:series) do
    [
      @tv_parent,
      @tv_webdl,
      @tv_foreign,
      @tv_sd,
      @tv_hd,
      @tv_uhd,
      @tv_other,
      @tv_sport,
      @tv_anime,
      @tv_documentary
    ]
  end

  # Mixed library type searches across all video content
  def categories_for_type(:mixed) do
    categories_for_type(:movies) ++ categories_for_type(:series)
  end

  # Unknown types return empty list (no category filter)
  def categories_for_type(_), do: []

  @doc """
  Returns the parent category ID for a library type.

  Useful when you want to search just the main category without subcategories.

  ## Examples

      iex> CategoryMapping.parent_category(:movies)
      2000

      iex> CategoryMapping.parent_category(:series)
      5000
  """
  @spec parent_category(atom()) :: integer() | nil
  def parent_category(:movies), do: @movies_parent
  def parent_category(:series), do: @tv_parent
  def parent_category(:mixed), do: nil
  def parent_category(_), do: nil

  @doc """
  Returns category name for a given category ID.

  ## Examples

      iex> CategoryMapping.category_name(2000)
      "Movies"

      iex> CategoryMapping.category_name(3040)
      "Audio/Lossless"
  """
  @spec category_name(integer()) :: String.t()
  def category_name(id) when is_integer(id) do
    case id do
      # Movies
      @movies_parent -> "Movies"
      @movies_foreign -> "Movies/Foreign"
      @movies_other -> "Movies/Other"
      @movies_sd -> "Movies/SD"
      @movies_hd -> "Movies/HD"
      @movies_uhd -> "Movies/UHD"
      @movies_bluray -> "Movies/BluRay"
      @movies_3d -> "Movies/3D"
      @movies_dvd -> "Movies/DVD"
      # Audio
      @audio_parent -> "Audio"
      @audio_mp3 -> "Audio/MP3"
      @audio_video -> "Audio/Video"
      @audio_audiobook -> "Audio/Audiobook"
      @audio_lossless -> "Audio/Lossless"
      @audio_other -> "Audio/Other"
      @audio_foreign -> "Audio/Foreign"
      # TV
      @tv_parent -> "TV"
      @tv_webdl -> "TV/WEB-DL"
      @tv_foreign -> "TV/Foreign"
      @tv_sd -> "TV/SD"
      @tv_hd -> "TV/HD"
      @tv_uhd -> "TV/UHD"
      @tv_other -> "TV/Other"
      @tv_sport -> "TV/Sport"
      @tv_anime -> "TV/Anime"
      @tv_documentary -> "TV/Documentary"
      # Adult
      @xxx_parent -> "XXX"
      @xxx_dvd -> "XXX/DVD"
      @xxx_wmv -> "XXX/WMV"
      @xxx_xvid -> "XXX/XviD"
      @xxx_x264 -> "XXX/x264"
      @xxx_uhd -> "XXX/UHD"
      @xxx_pack -> "XXX/Pack"
      @xxx_imageset -> "XXX/ImageSet"
      @xxx_packs -> "XXX/Packs"
      @xxx_sd -> "XXX/SD"
      @xxx_webdl -> "XXX/WEB-DL"
      # Books
      @books_parent -> "Books"
      @books_foreign -> "Books/Foreign"
      @books_ebook -> "Books/EBook"
      @books_comics -> "Books/Comics"
      @books_magazines -> "Books/Magazines"
      @books_technical -> "Books/Technical"
      @books_other -> "Books/Other"
      @books_audiobook -> "Books/Audiobook"
      # Other
      @other_parent -> "Other"
      @other_misc -> "Other/Misc"
      @other_hashed -> "Other/Hashed"
      # Unknown
      _ -> "Unknown (#{id})"
    end
  end

  @doc """
  Checks if a category ID belongs to a given library type.

  ## Examples

      iex> CategoryMapping.category_matches_type?(2040, :movies)
      true

      iex> CategoryMapping.category_matches_type?(5000, :movies)
      false
  """
  @spec category_matches_type?(integer(), atom()) :: boolean()
  def category_matches_type?(category_id, library_type) do
    category_id in categories_for_type(library_type)
  end

  @doc """
  Returns the library type for a given category ID.

  ## Examples

      iex> CategoryMapping.type_for_category(2040)
      :movies

      iex> CategoryMapping.type_for_category(3000)
      :other
  """
  @spec type_for_category(integer()) :: atom()
  def type_for_category(category_id) when is_integer(category_id) do
    cond do
      category_id >= 2000 and category_id < 3000 -> :movies
      category_id >= 5000 and category_id < 6000 -> :series
      true -> :other
    end
  end

  @doc """
  Returns the Torznab category ID for a category name.

  This is used to convert Cardigann category names (like "Movies/HD" or "TV/Anime")
  to their standard Torznab numeric IDs.

  ## Examples

      iex> CategoryMapping.category_id_from_name("Movies/HD")
      2040

      iex> CategoryMapping.category_id_from_name("TV/Anime")
      5070

      iex> CategoryMapping.category_id_from_name("Unknown")
      nil
  """
  @spec category_id_from_name(String.t()) :: integer() | nil
  def category_id_from_name(name) when is_binary(name) do
    # Normalize the name for lookup (case-insensitive)
    normalized = String.downcase(name)

    case normalized do
      # Movies
      "movies" -> @movies_parent
      "movies/foreign" -> @movies_foreign
      "movies/other" -> @movies_other
      "movies/sd" -> @movies_sd
      "movies/hd" -> @movies_hd
      "movies/uhd" -> @movies_uhd
      "movies/bluray" -> @movies_bluray
      "movies/blu-ray" -> @movies_bluray
      "movies/3d" -> @movies_3d
      "movies/dvd" -> @movies_dvd
      "movies/divx/xvid" -> @movies_sd
      "movies/h.264/x264" -> @movies_hd
      "movies/hevc/x265" -> @movies_hd
      "movies/mp4" -> @movies_sd
      "movies/dubs/dual audio" -> @movies_foreign
      "movies/bollywood" -> @movies_foreign
      "movies/svcd/vcd" -> @movies_sd
      # Audio
      "audio" -> @audio_parent
      "audio/mp3" -> @audio_mp3
      "audio/video" -> @audio_video
      "audio/audiobook" -> @audio_audiobook
      "audio/lossless" -> @audio_lossless
      "audio/other" -> @audio_other
      "audio/foreign" -> @audio_foreign
      "music" -> @audio_parent
      "music/mp3" -> @audio_mp3
      "music/lossless" -> @audio_lossless
      "music/video" -> @audio_video
      "music/dvd" -> @audio_parent
      "music/radio" -> @audio_other
      "music/other" -> @audio_other
      "music/album" -> @audio_parent
      "music/box set" -> @audio_parent
      "music/discography" -> @audio_parent
      "music/single" -> @audio_parent
      "music/concerts" -> @audio_video
      "music/aac" -> @audio_mp3
      # TV
      "tv" -> @tv_parent
      "tv/web-dl" -> @tv_webdl
      "tv/webdl" -> @tv_webdl
      "tv/foreign" -> @tv_foreign
      "tv/sd" -> @tv_sd
      "tv/hd" -> @tv_hd
      "tv/uhd" -> @tv_uhd
      "tv/other" -> @tv_other
      "tv/sport" -> @tv_sport
      "tv/anime" -> @tv_anime
      "tv/documentary" -> @tv_documentary
      "tv/dvd" -> @tv_parent
      "tv/divx/xvid" -> @tv_sd
      "tv/svcd/vcd" -> @tv_sd
      "tv/hevc/x265" -> @tv_hd
      "tv/cartoons" -> @tv_anime
      # Adult
      "xxx" -> @xxx_parent
      "xxx/dvd" -> @xxx_dvd
      "xxx/wmv" -> @xxx_wmv
      "xxx/xvid" -> @xxx_xvid
      "xxx/x264" -> @xxx_x264
      "xxx/uhd" -> @xxx_uhd
      "xxx/pack" -> @xxx_pack
      "xxx/imageset" -> @xxx_imageset
      "xxx/packs" -> @xxx_packs
      "xxx/sd" -> @xxx_sd
      "xxx/web-dl" -> @xxx_webdl
      "xxx/video" -> @xxx_dvd
      "xxx/picture" -> @xxx_imageset
      "xxx/magazine" -> @xxx_parent
      "xxx/hentai" -> @xxx_parent
      "xxx/games" -> @xxx_parent
      # Books
      "books" -> @books_parent
      "books/foreign" -> @books_foreign
      "books/ebook" -> @books_ebook
      "books/comics" -> @books_comics
      "books/magazines" -> @books_magazines
      "books/technical" -> @books_technical
      "books/other" -> @books_other
      "books/audiobook" -> @books_audiobook
      # Other
      "other" -> @other_parent
      "other/misc" -> @other_misc
      "other/hashed" -> @other_hashed
      "other/emulation" -> @other_parent
      "other/tutorial" -> @books_parent
      "other/sounds" -> @audio_other
      "other/e-books" -> @books_ebook
      "other/images" -> @other_parent
      "other/mobile phone" -> @other_parent
      "other/comics" -> @books_comics
      "other/other" -> @other_misc
      "other/nulled script" -> @other_parent
      "other/audiobook" -> @audio_audiobook
      # PC/Console categories (mapped to Other for now)
      "pc" -> @other_parent
      "pc/games" -> @other_parent
      "pc/mac" -> @other_parent
      "pc/mobile-android" -> @other_parent
      "pc/mobile-ios" -> @other_parent
      "pc/mobile-other" -> @other_parent
      "console" -> @other_parent
      "console/ps3" -> @other_parent
      "console/ps4" -> @other_parent
      "console/psp" -> @other_parent
      "console/xbox" -> @other_parent
      "console/xbox 360" -> @other_parent
      "console/wii" -> @other_parent
      "console/nds" -> @other_parent
      "console/3ds" -> @other_parent
      "console/other" -> @other_parent
      # Not found
      _ -> nil
    end
  end

  def category_id_from_name(_), do: nil

  @doc """
  Maps a site-specific category ID to a Torznab category ID using the provided category mappings.

  ## Parameters
    - site_category_id: The site-specific category ID (as string or integer)
    - category_mappings: List of category mapping entries from the Cardigann definition

  ## Returns
    - The Torznab category ID, or nil if no mapping found

  ## Examples

      iex> mappings = [%{"id" => 42, "cat" => "Movies/HD"}]
      iex> CategoryMapping.map_site_category_to_torznab("42", mappings)
      2040

      iex> CategoryMapping.map_site_category_to_torznab("999", mappings)
      nil
  """
  @spec map_site_category_to_torznab(String.t() | integer() | nil, list()) :: integer() | nil
  def map_site_category_to_torznab(nil, _mappings), do: nil
  def map_site_category_to_torznab(_site_id, nil), do: nil
  def map_site_category_to_torznab(_site_id, []), do: nil

  def map_site_category_to_torznab(site_category_id, category_mappings) do
    # Normalize site_category_id to string for comparison
    site_id_str = to_string(site_category_id)
    site_id_int = parse_category_id(site_category_id)

    # Find matching category mapping
    mapping =
      Enum.find(category_mappings, fn mapping ->
        mapping_id = Map.get(mapping, "id") || Map.get(mapping, :id)
        to_string(mapping_id) == site_id_str || mapping_id == site_id_int
      end)

    case mapping do
      nil ->
        nil

      mapping ->
        # Get the Torznab category name and convert to ID
        cat_name = Map.get(mapping, "cat") || Map.get(mapping, :cat)
        category_id_from_name(cat_name)
    end
  end

  defp parse_category_id(id) when is_integer(id), do: id

  defp parse_category_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_category_id(_), do: nil

  @doc """
  Returns all defined Torznab categories with their IDs and names.

  Useful for UI displays or debugging.
  """
  @spec all_categories() :: [%{id: integer(), name: String.t(), type: atom()}]
  def all_categories do
    all_ids()
    |> Enum.map(fn id ->
      %{
        id: id,
        name: category_name(id),
        type: type_for_category(id)
      }
    end)
  end

  # Private: All defined category IDs
  defp all_ids do
    [
      # Movies
      @movies_parent,
      @movies_foreign,
      @movies_other,
      @movies_sd,
      @movies_hd,
      @movies_uhd,
      @movies_bluray,
      @movies_3d,
      @movies_dvd,
      # Audio
      @audio_parent,
      @audio_mp3,
      @audio_video,
      @audio_audiobook,
      @audio_lossless,
      @audio_other,
      @audio_foreign,
      # TV
      @tv_parent,
      @tv_webdl,
      @tv_foreign,
      @tv_sd,
      @tv_hd,
      @tv_uhd,
      @tv_other,
      @tv_sport,
      @tv_anime,
      @tv_documentary,
      # Adult
      @xxx_parent,
      @xxx_dvd,
      @xxx_wmv,
      @xxx_xvid,
      @xxx_x264,
      @xxx_uhd,
      @xxx_pack,
      @xxx_imageset,
      @xxx_packs,
      @xxx_sd,
      @xxx_webdl,
      # Books
      @books_parent,
      @books_foreign,
      @books_ebook,
      @books_comics,
      @books_magazines,
      @books_technical,
      @books_other,
      @books_audiobook,
      # Other
      @other_parent,
      @other_misc,
      @other_hashed
    ]
  end
end
