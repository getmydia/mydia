defmodule Mydia.Library.PathAnchor do
  @moduledoc """
  Finds the folder that names a piece of media, using the path alone.

  This is the clustering primitive the import review page is built on. It runs
  before any provider call and does not care whether matching later succeeds,
  which is the whole point: the files that most need grouping are exactly the
  ones with no match to group by.

  `anchor_for/2` climbs from a file's directory toward the library root and
  stops at the first segment that names something rather than describing it. A
  season folder, a disc folder, a quality folder, and a release folder that
  merely repeats its parent are all descriptions, so they are climbed past.
  """

  alias Mydia.Library.PathParser

  @disc_pattern ~r/^(disc|disk|cd|dvd|part)[\s._-]?\d+$/i
  @disc_literals ~w(bdmv video_ts)
  @quality_pattern ~r/^(2160p|1080p|720p|576p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|hdtv|dvdrip|remux|proper|repack)$/i

  # Folder names that are never a title. Mirrors PathParser's own denylist.
  @root_folders ~w(media tv shows series television video videos library content data home usr mnt movies)

  @type classification :: {:season, non_neg_integer()} | :disc | :quality | :title

  @type anchor :: %{
          anchor_path: String.t(),
          cluster_key: String.t(),
          season_hint: non_neg_integer() | nil,
          climbed: [atom() | {:season, non_neg_integer()}]
        }

  @doc """
  Classifies one path segment.

  A redundant release folder is not a case here, because one segment cannot
  reveal that it repeats its parent. `anchor_for/2` handles that by comparing
  normalized keys as it climbs.
  """
  @spec classify_segment(String.t()) :: classification()
  def classify_segment(segment) when is_binary(segment) do
    cond do
      match?({:ok, _}, PathParser.season_from_segment(segment)) ->
        {:ok, n} = PathParser.season_from_segment(segment)
        {:season, n}

      String.downcase(segment) in @disc_literals ->
        :disc

      Regex.match?(@disc_pattern, segment) ->
        :disc

      Regex.match?(@quality_pattern, segment) ->
        :quality

      true ->
        :title
    end
  end

  @doc """
  Normalizes a folder name into a stable cluster key.

  Two folders naming the same show must produce the same key: every
  `import_candidates` row discovered under that folder stores it as
  `anchor_key`, which is what `Mydia.ImportCandidates.group_query/2`
  aggregates rows by, and therefore what makes a rescan reuse an earlier
  decision rather than starting a fresh group.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(name) when is_binary(name) do
    name
    |> String.replace(~r/\[[^\]]*\]/, " ")
    |> String.replace(~r/\((?:18|19|20)\d{2}\)/, " ")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  def normalize(_), do: ""

  @doc """
  Finds the anchor folder for a file path, relative to its library root.

  `anchor_path` is relative to `library_root` and is `""` for a file sitting
  loose in the root, which all cluster together under the key `"__root__"`.
  """
  @spec anchor_for(String.t(), String.t()) :: anchor()
  def anchor_for(path, library_root) when is_binary(path) and is_binary(library_root) do
    path
    |> Path.dirname()
    |> Path.relative_to(library_root)
    |> split_relative()
    |> climb([], nil)
  end

  defp split_relative(rel) when rel in [".", "", "/"], do: []
  defp split_relative(rel), do: rel |> Path.split() |> Enum.reject(&(&1 in [".", "/", ""]))

  # Walks from the deepest segment upward. `above` is the prefix over the
  # segment under test, so stopping means the anchor is `above ++ [segment]`.
  defp climb([], _climbed, _season), do: loose_file()

  defp climb(segments, climbed, season) do
    {above, [segment]} = Enum.split(segments, length(segments) - 1)

    case classify_segment(segment) do
      {:season, n} ->
        climb_past(above, segment, climbed ++ [{:season, n}], season || n)

      :disc ->
        climb_past(above, segment, climbed ++ [:disc], season)

      :quality ->
        climb_past(above, segment, climbed ++ [:quality], season)

      :title ->
        cond do
          # A denylisted or too-short folder never names media. With nothing
          # above it there is no anchor to find at all, so the file is loose.
          not valid_title?(segment) ->
            if above == [],
              do: loose_file(),
              else: climb(above, climbed ++ [:invalid_title], season)

          redundant?(segment, above) ->
            climb_past(above, segment, climbed ++ [:redundant_release], season)

          true ->
            anchor(above ++ [segment], climbed, season)
        end
    end
  end

  # Climbing past the shallowest segment would leave the library root itself as
  # the anchor, which would merge every such folder into a single group. So a
  # descriptive folder sitting directly under the root anchors on itself
  # instead. Its season is dropped: the folder IS the anchor, so there is no
  # separate show folder for that season to qualify.
  defp climb_past([], segment, climbed, _season), do: anchor([segment], climbed, nil)
  defp climb_past(above, _segment, climbed, season), do: climb(above, climbed, season)

  # A release folder that merely repeats its parent, e.g.
  # "The Wire/The.Wire.S01.1080p.BluRay/". The parent is the better anchor.
  defp redundant?(_segment, []), do: false

  defp redundant?(segment, above) do
    parent = List.last(above)
    parent_key = normalize(parent)

    parent_key != "" and String.starts_with?(normalize(segment), parent_key)
  end

  defp valid_title?(segment) do
    normalized = String.downcase(segment)

    normalized not in @root_folders and
      String.length(segment) >= 2 and
      not String.starts_with?(segment, ".")
  end

  defp anchor(segments, climbed, season) do
    anchor_path = Path.join(segments)

    %{
      anchor_path: anchor_path,
      cluster_key: normalize(List.last(segments)),
      season_hint: season,
      climbed: climbed
    }
  end

  defp loose_file do
    %{anchor_path: "", cluster_key: "__root__", season_hint: nil, climbed: []}
  end
end
