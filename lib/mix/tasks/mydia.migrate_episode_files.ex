defmodule Mix.Tasks.Mydia.MigrateEpisodeFiles do
  @moduledoc """
  Migrates TV episode files that are in the show root directory to proper Season folders.

  This task:
  - Finds all media files for TV show episodes
  - Checks if they're in the show root directory (not in a Season folder)
  - Parses the filename to extract season/episode info
  - Creates the proper Season XX folder
  - Moves the file and updates the database

  ## Usage

      mix mydia.migrate_episode_files

  ## Options

      --dry-run - Show what would be done without making changes
      --show-title TITLE - Only migrate files for a specific show

  ## Examples

      # Show what would be migrated
      mix mydia.migrate_episode_files --dry-run

      # Migrate files for The Witcher only
      mix mydia.migrate_episode_files --show-title "The Witcher"

      # Migrate all files
      mix mydia.migrate_episode_files
  """

  use Mix.Task
  require Logger

  alias Mydia.{Library, Repo}
  alias Mydia.Library.{MediaFile, FileParser}
  alias Mydia.Media.{Episode, MediaItem}
  import Ecto.Query

  @shortdoc "Migrates episode files to proper Season folders"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [dry_run: :boolean, show_title: :string],
        aliases: [d: :dry_run, s: :show_title]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    show_title = Keyword.get(opts, :show_title)

    if dry_run do
      Mix.shell().info("🔍 DRY RUN MODE - No changes will be made\n")
    end

    migrate_episode_files(dry_run, show_title)
  end

  defp migrate_episode_files(dry_run, show_title_filter) do
    # Find all media files that have an episode_id
    query =
      from mf in MediaFile,
        join: e in Episode,
        on: mf.episode_id == e.id,
        join: mi in MediaItem,
        on: e.media_item_id == mi.id,
        where: mi.type == "tv_show",
        preload: [:library_path, episode: {e, media_item: mi}],
        order_by: [mi.title, e.season_number, e.episode_number]

    query =
      if show_title_filter do
        where(query, [_mf, _e, mi], mi.title == ^show_title_filter)
      else
        query
      end

    media_files = Repo.all(query)

    Mix.shell().info("📺 Found #{length(media_files)} episode files to check\n")

    # Process each file
    results =
      media_files
      |> Enum.map(fn media_file ->
        migrate_file(media_file, dry_run)
      end)
      |> Enum.group_by(fn {status, _} -> status end)

    # Print summary
    print_summary(results, dry_run)
  end

  defp migrate_file(media_file, dry_run) do
    episode = media_file.episode
    show = episode.media_item
    file_path = MediaFile.absolute_path(media_file)

    # Check if file exists
    if File.exists?(file_path) do
      # Parse the filename
      parsed = FileParser.parse(Path.basename(file_path))

      # Check if the file is in a Season folder already
      path_parts = Path.split(file_path)
      parent_dir = Enum.at(path_parts, -2)

      if parent_dir && String.match?(parent_dir, ~r/^Season \d{2}$/) do
        # Already in a season folder
        {:already_organized, %{file: file_path, show: show.title}}
      else
        # File needs to be moved
        season_number = parsed.season || episode.season_number
        episode_number = List.first(parsed.episodes) || episode.episode_number

        # Build the correct destination path
        show_dir = Path.dirname(file_path)
        season_folder = "Season #{String.pad_leading("#{season_number}", 2, "0")}"
        dest_dir = Path.join(show_dir, season_folder)
        dest_path = Path.join(dest_dir, Path.basename(file_path))

        if dry_run do
          Mix.shell().info("""
          📁 Would move file:
             Show: #{show.title}
             Season: #{season_number}, Episode: #{episode_number}
             From: #{file_path}
             To:   #{dest_path}
          """)

          {:would_migrate, %{file: file_path, show: show.title, season: season_number}}
        else
          # Create the season folder
          File.mkdir_p!(dest_dir)

          # Move the file
          case File.rename(file_path, dest_path) do
            :ok ->
              # Calculate new relative path
              library_path_root = media_file.library_path.path
              new_relative_path = String.replace_prefix(dest_path, library_path_root <> "/", "")

              # Update the database with new relative path
              {:ok, _} =
                Library.update_media_file(media_file, %{relative_path: new_relative_path})

              Mix.shell().info("""
              ✅ Moved file:
                 Show: #{show.title}
                 Season: #{season_number}, Episode: #{episode_number}
                 To: #{dest_path}
              """)

              {:migrated, %{file: dest_path, show: show.title, season: season_number}}

            {:error, reason} ->
              Mix.shell().error("""
              ❌ Failed to move file:
                 Show: #{show.title}
                 File: #{file_path}
                 Error: #{inspect(reason)}
              """)

              {:error, %{file: file_path, show: show.title, reason: reason}}
          end
        end
      end
    else
      {:missing, %{file: file_path, show: show.title}}
    end
  end

  defp print_summary(results, dry_run) do
    Mix.shell().info("\n📊 Summary:")
    Mix.shell().info("=" |> String.duplicate(50))

    if dry_run do
      would_migrate = Map.get(results, :would_migrate, [])
      Mix.shell().info("Would migrate: #{length(would_migrate)} files")
    else
      migrated = Map.get(results, :migrated, [])
      Mix.shell().info("✅ Migrated: #{length(migrated)} files")
    end

    already_organized = Map.get(results, :already_organized, [])
    Mix.shell().info("✓ Already organized: #{length(already_organized)} files")

    missing = Map.get(results, :missing, [])

    if missing != [] do
      Mix.shell().info("⚠️  Missing files: #{length(missing)}")
    end

    errors = Map.get(results, :error, [])

    if errors != [] do
      Mix.shell().error("❌ Errors: #{length(errors)}")
    end

    Mix.shell().info("=" |> String.duplicate(50))

    if dry_run do
      Mix.shell().info("\n💡 Run without --dry-run to perform the migration")
    end
  end
end
