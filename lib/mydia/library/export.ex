defmodule Mydia.Library.Export do
  @moduledoc """
  Builds a portable catalog of the library: one row per media item, as JSON or
  CSV. Served by `MydiaWeb.Api.LibraryExportController`.

  File counts come from `MediaFile.versions/0` (untrashed, not extras). An
  episode's file carries `episode_id` with `media_item_id` NULL, so a file's
  owner is `coalesce(mf.media_item_id, episode.media_item_id)`. Episodes with
  files are counted through `media_file_episodes`, because `episode_id` only
  names a multi-episode file's first episode.

  Each row also carries its files as `Mydia.Library.Export.FileRow`s (see
  `file_rows/0`): nested under `files` in the JSON, flattened by
  `to_files_csv/1`, and left out of the per-item CSV.

  The JSON envelope uses the `items` key that
  `Mydia.ImportLists.Provider.CustomURL` reads, so a hosted export is a valid
  import list feed. Version 2 added `files`; every version 1 key is unchanged.
  """

  import Ecto.Query

  alias Jason.OrderedObject
  alias Mydia.Library.{MediaFile, MediaFileEpisode}
  alias Mydia.Library.Export.{FileRow, Row}
  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo
  alias Mydia.Settings.{LibraryPath, QualityProfile}

  @format "mydia-library"
  @version 2
  @identity_fields [:type, :title, :year, :tmdb_id, :tvdb_id, :imdb_id]

  @doc "Every media item as an export row with its files, sorted by type, title, year."
  @spec rows() :: [Row.t()]
  def rows do
    episodes = episode_totals()
    covered = covered_episode_totals()
    file_rows = file_rows()

    items_query()
    |> Repo.all()
    |> Enum.map(&to_row(&1, episodes, covered, file_rows))
    |> Enum.sort_by(&{&1.type, String.downcase(&1.title), &1.year})
  end

  @doc """
  Every version file (untrashed, not an extra) as a `FileRow`, grouped by its
  owning media item and ordered by season, episode, path. Two queries in total:
  the files, and the `media_file_episodes` links that give multi-episode files
  their range.
  """
  @spec file_rows() :: %{optional(term()) => [FileRow.t()]}
  def file_rows do
    links = episode_links()

    from(mf in MediaFile.versions(),
      left_join: e in Episode,
      on: e.id == mf.episode_id,
      left_join: lp in LibraryPath,
      on: lp.id == mf.library_path_id,
      where: not is_nil(coalesce(mf.media_item_id, e.media_item_id)),
      select: %{
        owner_id: coalesce(mf.media_item_id, e.media_item_id),
        id: mf.id,
        relative_path: mf.relative_path,
        legacy_path: mf.path,
        library_path: lp.path,
        size: mf.size,
        resolution: mf.resolution,
        codec: mf.codec,
        hdr_format: mf.hdr_format,
        audio_codec: mf.audio_codec,
        metadata: mf.metadata,
        season: e.season_number,
        episode: e.episode_number
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.owner_id, &to_file_row(&1, Map.get(links, &1.id)))
    |> Map.new(fn {owner_id, rows} -> {owner_id, Enum.sort_by(rows, &file_sort_key/1)} end)
  end

  @doc "JSON envelope with ordered keys; `items` is readable by the Custom URL import list."
  @spec to_json([Row.t()]) :: iodata()
  def to_json(rows) do
    OrderedObject.new([
      {"format", @format},
      {"version", @version},
      {"exported_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()},
      {"mydia_version", Mydia.System.app_version()},
      {"items", Enum.map(rows, &json_item/1)}
    ])
    |> Jason.encode_to_iodata!()
  end

  @doc "RFC 4180 CSV with a header row. UTF-8, no BOM, CRLF."
  @spec to_csv([Row.t()]) :: iodata()
  def to_csv(rows) do
    header = Enum.map(Row.fields(), &Atom.to_string/1)
    Mydia.Library.Export.CSV.dump_to_iodata([header | Enum.map(rows, &csv_cells/1)])
  end

  @doc """
  RFC 4180 CSV with one row per file: the item identity columns
  (`type, title, year, tmdb_id, tvdb_id, imdb_id`) followed by the
  `FileRow` columns. Items without files contribute no rows.
  """
  @spec to_files_csv([Row.t()]) :: iodata()
  def to_files_csv(rows) do
    header = Enum.map(@identity_fields ++ FileRow.fields(), &Atom.to_string/1)

    lines =
      for %Row{files: files} = row <- rows, file <- files do
        csv_cells(row, @identity_fields) ++ csv_cells(file, FileRow.fields())
      end

    Mydia.Library.Export.CSV.dump_to_iodata([header | lines])
  end

  @doc "Download filename for the given format, dated in UTC."
  @spec filename(:json | :csv | :files_csv, DateTime.t()) :: String.t()
  def filename(format, %DateTime{} = at) when format in [:json, :csv, :files_csv] do
    date = at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date() |> Date.to_iso8601()

    case format do
      :files_csv -> "mydia-library-files-#{date}.csv"
      _ -> "mydia-library-#{date}.#{format}"
    end
  end

  defp json_item(%Row{} = row) do
    (json_pairs(row, Row.fields()) ++
       [{"files", Enum.map(row.files, &OrderedObject.new(json_pairs(&1, FileRow.fields())))}])
    |> OrderedObject.new()
  end

  defp json_pairs(struct, fields) do
    Enum.map(ordered_values(struct, fields), fn {k, v} -> {Atom.to_string(k), json_value(v)} end)
  end

  defp csv_cells(%Row{} = row), do: csv_cells(row, Row.fields())

  defp csv_cells(struct, fields),
    do: Enum.map(ordered_values(struct, fields), fn {_k, v} -> csv_value(v) end)

  defp ordered_values(struct, fields), do: Enum.map(fields, &{&1, Map.fetch!(struct, &1)})

  defp json_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp json_value(v), do: v

  defp csv_value(nil), do: ""
  defp csv_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp csv_value(v) when is_binary(v), do: v
  defp csv_value(v), do: to_string(v)

  defp items_query do
    from(m in MediaItem,
      left_join: qp in QualityProfile,
      on: qp.id == m.quality_profile_id,
      left_join: lp in LibraryPath,
      on: lp.id == m.library_path_id,
      select: %{item: m, quality_profile: qp.name, library_path: lp.path}
    )
  end

  # %{media_item_id => episode_count}
  defp episode_totals do
    from(e in Episode, group_by: e.media_item_id, select: {e.media_item_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  # %{media_item_id => episodes_with_files}
  defp covered_episode_totals do
    from(link in MediaFileEpisode,
      join: mf in subquery(MediaFile.versions()),
      on: mf.id == link.media_file_id,
      join: e in Episode,
      on: e.id == link.episode_id,
      group_by: e.media_item_id,
      select: {e.media_item_id, count(e.id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # %{media_file_id => [{season_number, episode_number}]}, for version files only.
  defp episode_links do
    from(link in MediaFileEpisode,
      join: mf in subquery(MediaFile.versions()),
      on: mf.id == link.media_file_id,
      join: e in Episode,
      on: e.id == link.episode_id,
      select: {link.media_file_id, e.season_number, e.episode_number}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})
  end

  defp to_file_row(f, links) do
    path = file_path(f)
    {season, episode} = episode_span(f, links)
    streams = streams(f.metadata)
    video = Enum.find(streams, &match?(%StreamInfo{type: :video}, &1))
    audio = Enum.find(streams, &match?(%StreamInfo{type: :audio}, &1))

    %FileRow{
      path: path,
      library_path: f.library_path,
      size_bytes: f.size,
      resolution: f.resolution,
      video_codec: f.codec,
      video_profile: video && video.profile,
      bit_depth: video && video.bit_depth,
      hdr_format: f.hdr_format && Atom.to_string(f.hdr_format),
      audio_codec: f.audio_codec,
      audio_channels: audio_channels(audio),
      container: container(path),
      season: season,
      episode: episode
    }
  end

  # Same shape as MediaFile.storage_path/1 (an s3:// root yields an s3:// path),
  # falling back to the legacy column for a pre-invariant row.
  defp file_path(%{library_path: root, relative_path: rel})
       when is_binary(root) and is_binary(rel),
       do: Path.join(root, rel)

  defp file_path(%{relative_path: rel, legacy_path: legacy}), do: legacy || rel

  # A multi-episode file's links give its range; a single-episode file may only
  # have episode_id (see lib/mydia/media/README.md), so fall back to that.
  defp episode_span(_f, [_, _ | _] = links) do
    [{season, first} | _] = sorted = Enum.sort(links)
    {_, last} = List.last(sorted)
    {season, if(first == last, do: to_string(first), else: "#{first}-#{last}")}
  end

  defp episode_span(_f, [{season, episode}]), do: {season, to_string(episode)}
  defp episode_span(%{season: season, episode: nil}, _), do: {season, nil}
  defp episode_span(%{season: season, episode: episode}, _), do: {season, to_string(episode)}

  defp streams(%FileMetadata{streams: streams}) when is_list(streams), do: streams
  defp streams(_), do: []

  defp audio_channels(%StreamInfo{channel_layout: layout})
       when is_binary(layout) and layout != "",
       do: layout

  defp audio_channels(%StreamInfo{channels: channels}) when is_integer(channels),
    do: Integer.to_string(channels)

  defp audio_channels(_), do: nil

  defp container(nil), do: nil

  defp container(path) do
    case Path.extname(path) do
      "." <> ext when ext != "" -> String.downcase(ext)
      _ -> nil
    end
  end

  defp file_sort_key(%FileRow{season: season, episode: episode, path: path}) do
    {season || 0, episode_sort_number(episode), path || ""}
  end

  defp episode_sort_number(nil), do: 0

  defp episode_sort_number(episode) do
    case Integer.parse(episode) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_row(%{item: m} = r, episodes, covered, file_rows) do
    files = Map.get(file_rows, m.id, [])
    tv? = m.type == "tv_show"

    %Row{
      type: m.type,
      title: m.title,
      original_title: m.original_title,
      year: m.year,
      tmdb_id: m.tmdb_id,
      tvdb_id: m.tvdb_id,
      imdb_id: m.imdb_id,
      metadata_source: m.metadata_source && Atom.to_string(m.metadata_source),
      category: m.category,
      monitored: m.monitored,
      quality_profile: r.quality_profile,
      library_path: r.library_path,
      file_count: length(files),
      size_bytes: files |> Enum.map(&(&1.size_bytes || 0)) |> Enum.sum(),
      episode_count: if(tv?, do: Map.get(episodes, m.id, 0)),
      episodes_with_files: if(tv?, do: Map.get(covered, m.id, 0)),
      added_at: m.inserted_at,
      files: files
    }
  end
end
