defmodule Mix.Tasks.Mydia.NfoExport do
  @moduledoc """
  Generates Jellyfin-compatible NFO metadata files for media items in enabled library paths.

  This task writes NFO XML files alongside media files on disk. Only library paths
  with `write_nfo` enabled are processed (unless --all is specified).

  ## Usage

      mix mydia.nfo_export

  ## Options

      --library-path-id <id> - Export only for a specific library path
      --all                  - Export for all library paths (ignores write_nfo setting)
      --dry-run              - Show what would be written without writing files

  ## Examples

      # Export for all library paths with write_nfo enabled
      mix mydia.nfo_export

      # Export for a specific library path
      mix mydia.nfo_export --library-path-id abc123

      # Preview what would be written
      mix mydia.nfo_export --dry-run

      # Export for all library paths regardless of write_nfo setting
      mix mydia.nfo_export --all
  """

  use Mix.Task

  alias Mydia.{Repo, Settings}
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.NfoWriter
  import Ecto.Query

  @shortdoc "Generate Jellyfin NFO metadata files for media items"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [library_path_id: :string, dry_run: :boolean, all: :boolean],
        aliases: [d: :dry_run]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    export_all = Keyword.get(opts, :all, false)
    library_path_id = Keyword.get(opts, :library_path_id)

    library_paths = get_library_paths(library_path_id, export_all)

    if library_paths == [] do
      Mix.shell().info("No library paths found with NFO export enabled.")
      Mix.shell().info("Enable 'Write NFO Files' in library path settings, or use --all flag.")
      :ok
    else
      Mix.shell().info("#{if dry_run, do: "[DRY RUN] ", else: ""}NFO Export")
      Mix.shell().info("Processing #{length(library_paths)} library path(s)...\n")

      totals =
        Enum.reduce(library_paths, %{written: 0, skipped: 0, errors: 0}, fn lp, acc ->
          Mix.shell().info("Library: #{lp.path} (#{lp.type})")
          result = process_library_path(lp, dry_run)

          Mix.shell().info(
            "  Written: #{result.written}, Skipped: #{result.skipped}, Errors: #{result.errors}\n"
          )

          %{
            written: acc.written + result.written,
            skipped: acc.skipped + result.skipped,
            errors: acc.errors + result.errors
          }
        end)

      Mix.shell().info(
        "Done! Total: #{totals.written} written, #{totals.skipped} skipped, #{totals.errors} errors"
      )
    end
  end

  defp get_library_paths(nil, false) do
    Settings.list_library_paths()
    |> Enum.filter(fn path ->
      path.write_nfo and path.type in [:movies, :series, :mixed]
    end)
  end

  defp get_library_paths(nil, true) do
    Settings.list_library_paths()
    |> Enum.filter(&(&1.type in [:movies, :series, :mixed]))
  end

  defp get_library_paths(id, _export_all) do
    [Settings.get_library_path!(id)]
  rescue
    Ecto.NoResultsError ->
      Mix.shell().error("Library path #{id} not found")
      []
  end

  defp process_library_path(library_path, dry_run) do
    # Find all media items that have files in this library path
    media_item_ids =
      MediaFile
      |> where([mf], mf.library_path_id == ^library_path.id)
      |> where([mf], is_nil(mf.trashed_at))
      |> where([mf], not is_nil(mf.relative_path))
      |> select([mf], mf.media_item_id)
      |> distinct(true)
      |> Repo.all()

    # Batch-load media items in chunks to avoid N+1 queries
    media_item_ids
    |> Enum.chunk_every(100)
    |> Enum.reduce(%{written: 0, skipped: 0, errors: 0}, fn batch_ids, acc ->
      media_items =
        MediaItem
        |> where([m], m.id in ^batch_ids)
        |> Repo.all()
        |> Repo.preload([:episodes, media_files: :library_path])

      Enum.reduce(media_items, acc, fn media_item, inner_acc ->
        process_media_item(media_item, library_path, dry_run, inner_acc)
      end)
    end)
  end

  defp process_media_item(media_item, library_path, dry_run, acc) do
    if is_nil(media_item.metadata) do
      %{acc | skipped: acc.skipped + 1}
    else
      count = NfoWriter.count_nfo_files(media_item, library_path)

      if dry_run do
        Mix.shell().info("  [dry-run] #{media_item.title} - #{count} NFO file(s)")
        %{acc | written: acc.written + count}
      else
        NfoWriter.write_for_media_item(media_item, library_path)
        %{acc | written: acc.written + count}
      end
    end
  end
end
