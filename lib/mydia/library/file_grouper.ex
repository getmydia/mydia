defmodule Mydia.Library.FileGrouper do
  @moduledoc """
  Groups matched media files hierarchically for organized display and processing.

  This module provides functionality to organize matched media files into a
  hierarchical structure suitable for display in the import workflow:

  - TV shows are grouped by series → seasons → episodes
  - Movies are kept in a flat list
  - Unmatched files are kept separately

  ## Example

      matched_files = [
        %{file: file1, match_result: %{title: "Show A", parsed_info: %{type: :tv_show, season: 1, episodes: [1]}}},
        %{file: file2, match_result: %{title: "Movie B", parsed_info: %{type: :movie}}},
        %{file: file3, match_result: nil}
      ]

      FileGrouper.group_files(matched_files)
      # Returns:
      # %{
      #   series: [
      #     %GroupedSeries{
      #       title: "Show A",
      #       seasons: [
      #         %GroupedSeason{season_number: 1, episodes: [%GroupedEpisode{file: file1, index: 0, ...}]}
      #       ]
      #     }
      #   ],
      #   movies: [%GroupedFile{file: file2, index: 1, ...}],
      #   ungrouped: [%GroupedFile{file: file3, index: 2, ...}]
      # }
  """

  alias Mydia.Library.Structs.{GroupedEpisode, GroupedFile, GroupedSeason, GroupedSeries}
  alias Mydia.Library.Structs.MatchResult

  # Internal accumulator structs for grouping process
  defmodule SeasonState do
    @moduledoc false
    @enforce_keys [:season_number, :episodes]
    defstruct [:season_number, :episodes]

    @type t :: %__MODULE__{
            season_number: non_neg_integer(),
            episodes: [GroupedEpisode.t()]
          }

    @spec new(map()) :: t()
    def new(%{season_number: season_number}) do
      %__MODULE__{
        season_number: season_number,
        episodes: []
      }
    end
  end

  defmodule GroupingState do
    @moduledoc false
    @enforce_keys [:title, :provider_id, :year, :seasons]
    defstruct [:title, :provider_id, :year, :seasons]

    @type t :: %__MODULE__{
            title: String.t(),
            provider_id: String.t(),
            year: non_neg_integer() | nil,
            seasons: %{non_neg_integer() => SeasonState.t()}
          }

    @spec new(map()) :: t()
    def new(%{title: title, provider_id: provider_id, year: year}) do
      %__MODULE__{
        title: title,
        provider_id: provider_id,
        year: year,
        seasons: %{}
      }
    end
  end

  @type matched_file :: %{
          file: map(),
          match_result: MatchResult.t() | nil,
          import_status: atom()
        }

  @type episode :: GroupedEpisode.t()
  @type season :: GroupedSeason.t()
  @type series :: GroupedSeries.t()

  @type grouped_files :: %{
          series: [series()],
          movies: [GroupedFile.t()],
          ungrouped: [GroupedFile.t()]
        }

  @doc """
  Groups matched files hierarchically by type (series, movies, ungrouped).

  Takes a list of matched files and organizes them into a structure suitable
  for display and processing. Files are indexed for easy reference.

  TV shows are grouped by series and season, with episodes sorted within each season.
  Movies are kept in a flat list. Files without matches are placed in the ungrouped list.

  ## Parameters

    * `matched_files` - List of matched file maps, each containing:
      - `:file` - The file information
      - `:match_result` - The metadata match (or nil if no match)
      - `:import_status` - The import status

  ## Returns

  A map with three keys:
    * `:series` - List of series maps, each containing seasons and episodes
    * `:movies` - List of movie file maps with index added
    * `:ungrouped` - List of unmatched file maps with index added

  ## Examples

      iex> files = [
      ...>   %{file: %{path: "/tv/show.s01e01.mkv"}, match_result: %{title: "Show", provider_id: "123", year: 2020, parsed_info: %{type: :tv_show, season: 1, episodes: [1]}}},
      ...>   %{file: %{path: "/movies/movie.mkv"}, match_result: %{title: "Movie", provider_id: "456", year: 2021, parsed_info: %{type: :movie}}},
      ...>   %{file: %{path: "/unknown.mkv"}, match_result: nil}
      ...> ]
      iex> FileGrouper.group_files(files)
      %{
        series: [%{title: "Show", provider_id: "123", year: 2020, seasons: [...]}],
        movies: [%{file: %{path: "/movies/movie.mkv"}, index: 1, ...}],
        ungrouped: [%{file: %{path: "/unknown.mkv"}, index: 2, ...}]
      }
  """
  @spec group_files([matched_file()]) :: grouped_files()
  def group_files(matched_files) when is_list(matched_files) do
    matched_files
    |> Enum.with_index()
    |> Enum.reduce(%{series: %{}, movies: [], ungrouped: []}, &group_file/2)
    |> finalize_grouping()
  end

  @doc """
  Generates a unique key for a series based on title and provider ID.

  This key is used internally for grouping episodes of the same series together.

  ## Parameters

    * `match_or_series` - Either a match result map or a series map containing
      `:title` and `:provider_id` fields

  ## Returns

  A string in the format "title-provider_id"

  ## Examples

      iex> FileGrouper.series_key(%{title: "Breaking Bad", provider_id: "1396"})
      "Breaking Bad-1396"
  """
  @spec series_key(MatchResult.t() | series()) :: String.t()
  def series_key(%{title: title, provider_id: provider_id}) do
    "#{title}-#{provider_id}"
  end

  # Private functions

  # Group a single file into the accumulator
  defp group_file({matched_file, index}, acc) do
    case matched_file.match_result do
      nil ->
        # No match - add to ungrouped
        grouped_file =
          GroupedFile.new(%{
            file: matched_file.file,
            match_result: matched_file.match_result,
            import_status: matched_file.import_status,
            index: index
          })

        %{acc | ungrouped: acc.ungrouped ++ [grouped_file]}

      match when match.parsed_info.type == :tv_show ->
        # TV show episode - group by series and season
        group_tv_show_episode(matched_file, index, match, acc)

      match when match.parsed_info.type == :movie ->
        # Movie - add to movies list
        grouped_file =
          GroupedFile.new(%{
            file: matched_file.file,
            match_result: matched_file.match_result,
            import_status: matched_file.import_status,
            index: index
          })

        %{acc | movies: acc.movies ++ [grouped_file]}

      _other ->
        # Unknown type - add to ungrouped
        grouped_file =
          GroupedFile.new(%{
            file: matched_file.file,
            match_result: matched_file.match_result,
            import_status: matched_file.import_status,
            index: index
          })

        %{acc | ungrouped: acc.ungrouped ++ [grouped_file]}
    end
  end

  # Group a TV show episode into the series hierarchy
  defp group_tv_show_episode(matched_file, index, match, acc) do
    series_id = series_key(match)
    season_num = match.parsed_info.season || 0

    # Get or create series entry
    series_entry =
      Map.get(
        acc.series,
        series_id,
        GroupingState.new(%{
          title: match.title,
          provider_id: match.provider_id,
          year: match.year
        })
      )

    # Get or create season entry
    season_entry =
      Map.get(
        series_entry.seasons,
        season_num,
        SeasonState.new(%{season_number: season_num})
      )

    # Add episode to season
    episode_entry =
      GroupedEpisode.new(%{
        file: matched_file.file,
        match_result: matched_file.match_result,
        import_status: matched_file.import_status,
        index: index
      })

    updated_season = %SeasonState{
      season_entry
      | episodes: season_entry.episodes ++ [episode_entry]
    }

    updated_series = put_in(series_entry.seasons[season_num], updated_season)
    updated_series_map = Map.put(acc.series, series_id, updated_series)

    %{acc | series: updated_series_map}
  end

  # Convert series map to list and sort seasons
  defp finalize_grouping(grouped) do
    series_list =
      grouped.series
      |> Map.values()
      |> Enum.map(fn series ->
        seasons_list =
          series.seasons
          |> Map.values()
          |> Enum.map(fn season_state ->
            GroupedSeason.new(%{
              season_number: season_state.season_number,
              episodes: season_state.episodes
            })
          end)
          |> Enum.sort_by(& &1.season_number)

        GroupedSeries.new(%{
          title: series.title,
          provider_id: series.provider_id,
          year: series.year,
          seasons: seasons_list
        })
      end)
      |> Enum.sort_by(& &1.title)

    %{
      series: series_list,
      movies: grouped.movies,
      ungrouped: grouped.ungrouped
    }
  end
end
