defmodule MydiaWeb.MediaLive.Show.ExistingFiles do
  @moduledoc """
  What is already on disk for a Manual Search context, so the dialog can show
  it next to the releases being compared (#1051).

  Built from the media item the show page already preloads (untrashed files,
  extras included), so it costs no query.
  """

  alias Mydia.Indexers.QualityParser
  alias MydiaWeb.MediaLive.Show.SearchHelpers

  defstruct [
    :kind,
    :filename,
    :resolution,
    :codec,
    :size,
    :source,
    :on_disk,
    :total,
    extra_count: 0
  ]

  @type t :: %__MODULE__{}

  @doc """
  Summarizes the files for a search context, or nil when there is nothing on
  disk or the context has no single target (a whole-show search).
  """
  @spec summarize(map(), map() | nil) :: t() | nil
  def summarize(%{type: "movie"} = item, %{type: :media_item}),
    do: item |> Map.get(:media_files, []) |> versions() |> file_summary()

  def summarize(item, %{type: :episode, episode_id: episode_id}) do
    item
    |> episodes()
    |> Enum.find(&(to_string(&1.id) == to_string(episode_id)))
    |> case do
      nil -> nil
      episode -> episode.media_files |> versions() |> file_summary()
    end
  end

  def summarize(item, %{type: :season, season_number: season}) do
    episodes = item |> episodes() |> Enum.filter(&(&1.season_number == season))
    with_files = Enum.filter(episodes, &(versions(&1.media_files) != []))

    case with_files do
      [] ->
        nil

      _ ->
        qualities =
          with_files |> Enum.flat_map(&versions(&1.media_files)) |> Enum.map(&quality/1)

        %__MODULE__{
          kind: :season,
          on_disk: length(with_files),
          # Unaired episodes would make a complete season read as incomplete.
          total: Enum.count(episodes, &(aired?(&1) or &1 in with_files)),
          resolution: dominant(qualities, :resolution),
          source: dominant(qualities, :source),
          codec: dominant(qualities, :codec)
        }
    end
  end

  def summarize(_item, _context), do: nil

  defp file_summary([]), do: nil

  defp file_summary([first | rest]) do
    q = quality(first)

    %__MODULE__{
      kind: :file,
      filename: filename(first),
      extra_count: length(rest),
      resolution: q.resolution,
      codec: q.codec,
      source: q.source,
      size: first.size
    }
  end

  defp versions(files) when is_list(files), do: Enum.filter(files, &is_nil(&1.extra_kind))
  defp versions(_), do: []

  defp episodes(item) do
    case Map.get(item, :episodes) do
      episodes when is_list(episodes) -> episodes
      _ -> []
    end
  end

  defp filename(file), do: Path.basename(file.relative_path || file.path || "")

  # MediaFile has resolution and codec columns (codec as ffprobe names it) but
  # no source, so source always comes from the filename, and the columns fall
  # back to it when analysis has not filled them.
  defp quality(file) do
    parsed = QualityParser.parse(filename(file))

    %{
      resolution: file.resolution || parsed.resolution,
      codec: SearchHelpers.codec_family(file.codec || parsed.codec) || file.codec,
      source: parsed.source
    }
  end

  defp aired?(%{air_date: nil}), do: true
  defp aired?(%{air_date: date}), do: Date.compare(date, Date.utc_today()) != :gt

  # Most common non-nil value; ties break alphabetically so the line is stable.
  defp dominant(qualities, key) do
    qualities
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, value} end)
    |> case do
      [{value, _} | _] -> value
      [] -> nil
    end
  end
end
