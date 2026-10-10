defmodule Mydia.Media.Queries do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Media.Episode

  @doc false
  def apply_media_item_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:type, type}, query ->
        where(query, [m], m.type == ^type)

      {:monitored, monitored}, query ->
        where(query, [m], m.monitored == ^monitored)

      {:ids, ids}, query when is_list(ids) ->
        where(query, [m], m.id in ^ids)

      {:category, category}, query when is_atom(category) ->
        where(query, [m], m.category == ^to_string(category))

      {:category, category}, query when is_binary(category) ->
        where(query, [m], m.category == ^category)

      {:exclude_categories, []}, query ->
        query

      {:exclude_categories, categories}, query when is_list(categories) ->
        names = Enum.map(categories, &to_string/1)
        # `category` is nullable and SQL evaluates NULL NOT IN (...) to NULL,
        # which drops the row. An item that has not been classified yet must
        # stay on the page it is already on, so keep NULLs explicitly.
        where(query, [m], is_nil(m.category) or m.category not in ^names)

      {:library_path_type, library_type}, query ->
        filter_by_library_path_type(query, library_type)

      {:library_path_id, library_path_id}, query ->
        filter_by_library_path(query, library_path_id)

      {:search, search_term}, query when is_binary(search_term) ->
        search_pattern = "%#{String.downcase(search_term)}%"
        where(query, [m], like(fragment("lower(?)", m.title), ^search_pattern))

      {:added_since, datetime}, query ->
        where(query, [m], m.inserted_at >= ^datetime)

      {:limit, limit}, query when is_integer(limit) and limit > 0 ->
        limit(query, ^limit)

      {:order_by, field}, query when field in [:title, :year, :inserted_at] ->
        order_by(query, [m], asc: ^field)

      {:has_files, true}, query ->
        filter_by_has_files(query)

      {:category_in, []}, query ->
        query

      {:category_in, categories}, query when is_list(categories) ->
        names = Enum.map(categories, &to_string/1)
        where(query, [m], m.category in ^names)

      _other, query ->
        query
    end)
  end

  # Filter media items to only those that have at least one media file.
  # Movies: direct media_file association via media_item_id
  # TV Shows: indirect via episodes that have media files
  @doc false
  def filter_by_has_files(query) do
    movie_subquery =
      from mf in Mydia.Library.MediaFile,
        where: not is_nil(mf.media_item_id),
        select: mf.media_item_id,
        distinct: true

    episode_subquery =
      from mf in Mydia.Library.MediaFile,
        join: e in Episode,
        on: mf.episode_id == e.id,
        select: e.media_item_id,
        distinct: true

    where(
      query,
      [m],
      m.id in subquery(movie_subquery) or m.id in subquery(episode_subquery)
    )
  end

  # Filter media items by library path type using a subquery
  # This is more efficient than client-side filtering
  @doc false
  def filter_by_library_path_type(query, library_type) do
    # Subquery to get media_item_ids from media_files in library paths of this type
    media_item_subquery =
      from mf in Mydia.Library.MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        where: lp.type == ^library_type and not is_nil(mf.media_item_id),
        select: mf.media_item_id,
        distinct: true

    # Subquery to get media_item_ids from episodes that have media files in library paths of this type
    episode_subquery =
      from mf in Mydia.Library.MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        join: e in Mydia.Media.Episode,
        on: mf.episode_id == e.id,
        where: lp.type == ^library_type,
        select: e.media_item_id,
        distinct: true

    # Combine both: direct media files and episode media files
    where(
      query,
      [m],
      m.id in subquery(media_item_subquery) or m.id in subquery(episode_subquery)
    )
  end

  # An item is in a library when one of its current files is, reached either
  # directly or through an episode (episode files carry a NULL media_item_id).
  # An item with no current files falls back to its target library, so wanted
  # items still show up under the library they will download into.
  @doc false
  def filter_by_library_path(query, library_path_id) do
    direct =
      from mf in Mydia.Library.MediaFile.versions(),
        where: mf.library_path_id == ^library_path_id and not is_nil(mf.media_item_id),
        select: mf.media_item_id

    via_episode =
      from mf in Mydia.Library.MediaFile.versions(),
        join: mfe in Mydia.Library.MediaFileEpisode,
        on: mfe.media_file_id == mf.id,
        join: e in Mydia.Media.Episode,
        on: e.id == mfe.episode_id,
        where: mf.library_path_id == ^library_path_id,
        select: e.media_item_id

    # NOT IN over a subquery that yields a NULL drops every row, so both
    # has-files subqueries exclude NULLs explicitly.
    has_direct_files =
      from mf in Mydia.Library.MediaFile.versions(),
        where: not is_nil(mf.media_item_id),
        select: mf.media_item_id

    has_episode_files =
      from mf in Mydia.Library.MediaFile.versions(),
        join: mfe in Mydia.Library.MediaFileEpisode,
        on: mfe.media_file_id == mf.id,
        join: e in Mydia.Media.Episode,
        on: e.id == mfe.episode_id,
        where: not is_nil(e.media_item_id),
        select: e.media_item_id

    where(
      query,
      [m],
      m.id in subquery(direct) or m.id in subquery(via_episode) or
        (m.library_path_id == ^library_path_id and
           m.id not in subquery(has_direct_files) and
           m.id not in subquery(has_episode_files))
    )
  end
end
