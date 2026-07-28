defmodule Mydia.Library.MisplacedSeriesHealer do
  @moduledoc """
  Detects and relocates video files that landed in the wrong series folder.

  This is the opt-in repair counterpart to the MediaImport shared-download-dir
  fix. When a client (notably rqbit) lists a shared output folder, foreign
  `SxxExx` files can be imported into the wrong show's `Season XX/` directory.
  This healer walks series library folders, compares each file's unbound
  parsed title to the enclosing show folder, and either:

  1. Moves the file into the correct existing show's season folder (high
     confidence local title match), or
  2. Quarantines it under `{library}/_misplaced/{original_show}/...` when no
     confident home exists.

  **Not run automatically.** Title-similarity moves are easy to get wrong on
  real libraries (ambiguous names, multi-title releases, still-seeding
  hardlinks). Always dry-run first:

      MisplacedSeriesHealer.heal(dry_run: true)

  Then call `heal/1` (or enqueue `Mydia.Jobs.MisplacedSeriesHeal`) only after
  reviewing the reported actions.
  """

  require Logger

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Text
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  @video_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts .ts)
  @quarantine_dir "_misplaced"
  # Must disagree with the folder show at least this much to be considered foreign.
  @mismatch_threshold 0.5
  # Must agree with another local show at least this much to auto-relocate there.
  @relocate_threshold 0.8

  @type action ::
          {:relocate, source :: String.t(), dest :: String.t(), to_title :: String.t()}
          | {:quarantine, source :: String.t(), dest :: String.t(), parsed_title :: String.t()}
          | {:skip, source :: String.t(), reason :: atom()}

  @type result :: %{
          scanned: non_neg_integer(),
          relocated: non_neg_integer(),
          quarantined: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          actions: [action()]
        }

  @doc """
  Scan all monitored series library paths and heal misplaced files.

  Options:

  - `:dry_run` (default `false`) — report actions without moving files
  - `:library_path_id` — limit to a single library path
  """
  @spec heal(keyword()) :: result()
  def heal(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    library_paths = series_library_paths(opts)

    shows = Media.list_media_items(type: "tv_show")

    Enum.reduce(library_paths, empty_result(), fn library_path, acc ->
      heal_library_path(library_path, shows, dry_run?, acc)
    end)
  end

  defp series_library_paths(opts) do
    case Keyword.get(opts, :library_path_id) do
      nil ->
        Settings.list_library_paths()
        |> Enum.filter(&(&1.type in [:series, :mixed]))

      id ->
        case Settings.get_library_path!(id) do
          %LibraryPath{type: type} = lp when type in [:series, :mixed] -> [lp]
          _ -> []
        end
    end
  rescue
    Ecto.NoResultsError -> []
  end

  defp empty_result do
    %{scanned: 0, relocated: 0, quarantined: 0, skipped: 0, errors: 0, actions: []}
  end

  defp heal_library_path(%LibraryPath{} = library_path, shows, dry_run?, acc) do
    root = library_path.path

    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.reject(&(&1 in [".", "..", @quarantine_dir] or String.starts_with?(&1, ".")))
      |> Enum.reduce(acc, fn entry, acc ->
        show_dir = Path.join(root, entry)

        if File.dir?(show_dir) do
          heal_show_dir(root, entry, show_dir, shows, dry_run?, acc)
        else
          acc
        end
      end)
    else
      Logger.warning("Series library path does not exist, skipping heal", path: root)
      acc
    end
  end

  defp heal_show_dir(library_root, folder_name, show_dir, shows, dry_run?, acc) do
    folder_show = find_show_for_folder(folder_name, shows)

    show_dir
    |> list_videos_recursive()
    |> Enum.reduce(acc, fn path, acc ->
      heal_file(library_root, folder_name, folder_show, path, shows, dry_run?, acc)
    end)
  end

  defp find_show_for_folder(folder_name, shows) do
    Enum.max_by(
      shows,
      fn %MediaItem{title: title} ->
        Text.title_similarity(folder_name, title || "")
      end,
      fn -> nil end
    )
    |> case do
      nil ->
        nil

      %MediaItem{title: title} = item ->
        if Text.title_similarity(folder_name, title || "") >= @relocate_threshold do
          item
        else
          # Folder name doesn't confidently match any library show — still
          # use folder_name as the expected title for mismatch detection.
          %{title: folder_name, id: nil}
        end
    end
  end

  defp heal_file(library_root, folder_name, folder_show, path, shows, dry_run?, acc) do
    acc = %{acc | scanned: acc.scanned + 1}
    basename = Path.basename(path)
    parsed = ReleaseParser.parse(basename)
    parsed_title = parsed.title

    expected_title =
      case folder_show do
        %MediaItem{title: title} -> title
        %{title: title} -> title
        _ -> folder_name
      end

    cond do
      not is_binary(parsed_title) or parsed_title == "" ->
        record(acc, {:skip, path, :no_parsed_title}, :skipped)

      Text.title_similarity(parsed_title, expected_title) >= @mismatch_threshold ->
        record(acc, {:skip, path, :belongs_here}, :skipped)

      true ->
        relocate_or_quarantine(
          library_root,
          folder_name,
          path,
          parsed,
          parsed_title,
          shows,
          dry_run?,
          acc
        )
    end
  end

  defp relocate_or_quarantine(
         library_root,
         folder_name,
         path,
         parsed,
         parsed_title,
         shows,
         dry_run?,
         acc
       ) do
    case best_destination_show(parsed_title, shows) do
      {%MediaItem{} = dest_show, score} when score >= @relocate_threshold ->
        dest = destination_path(library_root, dest_show, parsed, Path.basename(path))
        action = {:relocate, path, dest, dest_show.title}

        if dry_run? do
          record(acc, action, :relocated)
        else
          case move_file(path, dest) do
            :ok ->
              Logger.info("Relocated misplaced series file",
                from: path,
                to: dest,
                show: dest_show.title
              )

              record(acc, action, :relocated)

            {:error, reason} ->
              Logger.error("Failed to relocate misplaced series file",
                from: path,
                to: dest,
                reason: inspect(reason)
              )

              %{
                acc
                | errors: acc.errors + 1,
                  actions: [{:skip, path, :move_failed} | acc.actions]
              }
          end
        end

      _ ->
        dest =
          Path.join([
            library_root,
            @quarantine_dir,
            sanitize_filename(folder_name),
            Path.basename(Path.dirname(path)),
            Path.basename(path)
          ])

        action = {:quarantine, path, dest, parsed_title}

        if dry_run? do
          record(acc, action, :quarantined)
        else
          case move_file(path, dest) do
            :ok ->
              Logger.info("Quarantined misplaced series file",
                from: path,
                to: dest,
                parsed_title: parsed_title
              )

              record(acc, action, :quarantined)

            {:error, reason} ->
              Logger.error("Failed to quarantine misplaced series file",
                from: path,
                to: dest,
                reason: inspect(reason)
              )

              %{
                acc
                | errors: acc.errors + 1,
                  actions: [{:skip, path, :move_failed} | acc.actions]
              }
          end
        end
    end
  end

  defp best_destination_show(parsed_title, shows) do
    shows
    |> Enum.map(fn %MediaItem{title: title} = item ->
      {item, Text.title_similarity(parsed_title, title || "")}
    end)
    |> Enum.max_by(fn {_item, score} -> score end, fn -> nil end)
  end

  defp destination_path(library_root, %MediaItem{title: title}, parsed, basename) do
    season_dir =
      case parsed.season do
        n when is_integer(n) ->
          Path.join(library_root, sanitize_filename(title))
          |> Path.join("Season #{String.pad_leading("#{n}", 2, "0")}")

        _ ->
          Path.join(library_root, sanitize_filename(title))
      end

    Path.join(season_dir, basename)
  end

  defp move_file(source, dest) do
    with :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- ensure_not_clobbering(dest),
         :ok <- File.rename(source, dest) do
      :ok
    else
      {:error, :exdev} ->
        # Cross-device rename — fall back to copy + delete
        with :ok <- File.cp(source, dest),
             :ok <- File.rm(source) do
          :ok
        end

      other ->
        other
    end
  end

  defp ensure_not_clobbering(dest) do
    if File.exists?(dest) do
      {:error, :destination_exists}
    else
      :ok
    end
  end

  defp list_videos_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) and not String.starts_with?(entry, ".") ->
              list_videos_recursive(path)

            video_file?(path) ->
              [path]

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp video_file?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @video_extensions and File.regular?(path)
  end

  defp sanitize_filename(name) do
    name
    |> String.replace(~r/[<>:"|?*]/, "")
    |> String.replace(~r/[\/\\]/, "-")
    |> String.trim()
  end

  defp record(acc, action, counter) do
    %{acc | counter => Map.fetch!(acc, counter) + 1, actions: [action | acc.actions]}
  end
end
