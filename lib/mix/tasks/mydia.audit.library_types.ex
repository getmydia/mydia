defmodule Mix.Tasks.Mydia.Audit.LibraryTypes do
  @moduledoc """
  Audits the database to identify media items that don't match their library path types.

  This task identifies:
  - Movies in :series-only library paths
  - TV shows in :movies-only library paths

  Library paths with type :mixed are allowed to contain both movies and TV shows.

  ## Usage

      mix mydia.audit.library_types

  ## Options

      --dry-run - Show what would be done without making changes (default)
      --fix - Apply fixes to resolve mismatches
      --verbose - Show detailed information about each mismatch

  ## Examples

      # Show all mismatches (dry-run by default)
      mix mydia.audit.library_types

      # Show detailed information
      mix mydia.audit.library_types --verbose

      # Apply fixes to resolve mismatches
      mix mydia.audit.library_types --fix
  """

  use Mix.Task
  require Logger

  alias Mydia.{Library, Repo, Settings}
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  import Ecto.Query

  @shortdoc "Audits library type mismatches between media items and library paths"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [dry_run: :boolean, fix: :boolean, verbose: :boolean],
        aliases: [d: :dry_run, f: :fix, v: :verbose]
      )

    dry_run = Keyword.get(opts, :dry_run, true)
    fix_mode = Keyword.get(opts, :fix, false)
    verbose = Keyword.get(opts, :verbose, false)

    # If --fix is specified, override dry_run to false
    dry_run = if fix_mode, do: false, else: dry_run

    if dry_run do
      Mix.shell().info("🔍 DRY RUN MODE - No changes will be made\n")
    end

    audit_library_types(dry_run, verbose)
  end

  defp audit_library_types(dry_run, verbose) do
    Mix.shell().info("📚 Auditing library type compatibility...\n")

    # Get all library paths
    library_paths = Settings.list_library_paths()

    Mix.shell().info("Found #{length(library_paths)} library paths")

    # Separate library paths by type
    movies_only_paths = Enum.filter(library_paths, &(&1.type == :movies))
    series_only_paths = Enum.filter(library_paths, &(&1.type == :series))
    mixed_paths = Enum.filter(library_paths, &(&1.type == :mixed))

    Mix.shell().info("  - Movies only: #{length(movies_only_paths)}")
    Mix.shell().info("  - Series only: #{length(series_only_paths)}")
    Mix.shell().info("  - Mixed: #{length(mixed_paths)}\n")

    # Find mismatches
    movies_in_series_libs = find_movies_in_series_libraries(series_only_paths, verbose)
    shows_in_movies_libs = find_tv_shows_in_movies_libraries(movies_only_paths, verbose)

    # Print summary
    print_summary(movies_in_series_libs, shows_in_movies_libs, dry_run)

    # Apply fixes if requested
    if not dry_run and (movies_in_series_libs != [] or shows_in_movies_libs != []) do
      apply_fixes(movies_in_series_libs, shows_in_movies_libs, library_paths)
    end
  end

  # Find movies (media_items with type="movie") in :series libraries
  defp find_movies_in_series_libraries(series_only_paths, verbose) do
    if Enum.empty?(series_only_paths) do
      []
    else
      Mix.shell().info("🎬 Checking for movies in series-only libraries...")

      series_path_strings = Enum.map(series_only_paths, & &1.path)

      query =
        from mf in MediaFile,
          join: mi in MediaItem,
          on: mf.media_item_id == mi.id,
          where: mi.type == "movie",
          preload: [:library_path, media_item: mi],
          select: mf

      media_files = Repo.all(query)

      # Filter to only files in series-only library paths
      mismatches =
        media_files
        |> Enum.filter(fn mf ->
          absolute_path = MediaFile.absolute_path(mf)
          Enum.any?(series_path_strings, &String.starts_with?(absolute_path, &1))
        end)
        |> Enum.map(fn mf ->
          absolute_path = MediaFile.absolute_path(mf)
          library_path = find_library_path_for_file(absolute_path, series_only_paths)

          %{
            media_file: mf,
            media_item: mf.media_item,
            library_path: library_path,
            issue: :movie_in_series_library
          }
        end)

      Mix.shell().info("  Found #{length(mismatches)} movies in series-only libraries\n")

      if verbose and mismatches != [] do
        print_detailed_mismatches(mismatches)
      end

      mismatches
    end
  end

  # Find TV shows (episodes) in :movies libraries
  defp find_tv_shows_in_movies_libraries(movies_only_paths, verbose) do
    if Enum.empty?(movies_only_paths) do
      []
    else
      Mix.shell().info("📺 Checking for TV shows in movies-only libraries...")

      movies_path_strings = Enum.map(movies_only_paths, & &1.path)

      query =
        from mf in MediaFile,
          join: e in Episode,
          on: mf.episode_id == e.id,
          join: mi in MediaItem,
          on: e.media_item_id == mi.id,
          where: mi.type == "tv_show",
          preload: [:library_path, episode: {e, media_item: mi}],
          select: mf

      media_files = Repo.all(query)

      # Filter to only files in movies-only library paths
      mismatches =
        media_files
        |> Enum.filter(fn mf ->
          absolute_path = MediaFile.absolute_path(mf)
          Enum.any?(movies_path_strings, &String.starts_with?(absolute_path, &1))
        end)
        |> Enum.map(fn mf ->
          absolute_path = MediaFile.absolute_path(mf)
          library_path = find_library_path_for_file(absolute_path, movies_only_paths)

          %{
            media_file: mf,
            episode: mf.episode,
            media_item: mf.episode.media_item,
            library_path: library_path,
            issue: :tv_show_in_movies_library
          }
        end)

      Mix.shell().info("  Found #{length(mismatches)} TV episodes in movies-only libraries\n")

      if verbose and mismatches != [] do
        print_detailed_mismatches(mismatches)
      end

      mismatches
    end
  end

  # Finds the library path that contains the given file path
  defp find_library_path_for_file(file_path, library_paths) do
    library_paths
    |> Enum.filter(fn library_path ->
      String.starts_with?(file_path, library_path.path)
    end)
    |> Enum.max_by(
      fn library_path -> String.length(library_path.path) end,
      fn -> nil end
    )
  end

  defp print_detailed_mismatches(mismatches) do
    Enum.each(mismatches, fn mismatch ->
      absolute_path = MediaFile.absolute_path(mismatch.media_file)

      case mismatch.issue do
        :movie_in_series_library ->
          Mix.shell().info("""
            ❌ Movie in series-only library:
               Title: #{mismatch.media_item.title} (#{mismatch.media_item.year})
               TMDB ID: #{mismatch.media_item.tmdb_id}
               File: #{absolute_path}
               Library: #{mismatch.library_path.path} (type: :series)
          """)

        :tv_show_in_movies_library ->
          Mix.shell().info("""
            ❌ TV episode in movies-only library:
               Show: #{mismatch.media_item.title}
               Episode: S#{String.pad_leading("#{mismatch.episode.season_number}", 2, "0")}E#{String.pad_leading("#{mismatch.episode.episode_number}", 2, "0")}
               TMDB ID: #{mismatch.media_item.tmdb_id}
               File: #{absolute_path}
               Library: #{mismatch.library_path.path} (type: :movies)
          """)
      end
    end)
  end

  defp print_summary(movies_in_series_libs, shows_in_movies_libs, dry_run) do
    Mix.shell().info("\n📊 Summary:")
    Mix.shell().info("=" |> String.duplicate(60))

    total_mismatches = length(movies_in_series_libs) + length(shows_in_movies_libs)

    Mix.shell().info("Total mismatches found: #{total_mismatches}")
    Mix.shell().info("  - Movies in series-only libraries: #{length(movies_in_series_libs)}")
    Mix.shell().info("  - TV shows in movies-only libraries: #{length(shows_in_movies_libs)}")

    Mix.shell().info("=" |> String.duplicate(60))

    cond do
      total_mismatches == 0 ->
        Mix.shell().info("\n✅ No mismatches found! All media items are in compatible libraries.")

      dry_run ->
        Mix.shell().info("""

        💡 To see detailed information about each mismatch, run:
           mix mydia.audit.library_types --verbose

        💡 To apply fixes, run:
           mix mydia.audit.library_types --fix
        """)

      true ->
        Mix.shell().info("\n✅ Fixes have been applied.")
    end
  end

  defp apply_fixes(movies_in_series_libs, shows_in_movies_libs, all_library_paths) do
    Mix.shell().info("\n🔧 Applying fixes...\n")

    # Find compatible libraries for migrations
    movies_compatible_paths =
      Enum.filter(all_library_paths, &(&1.type in [:movies, :mixed]))

    series_compatible_paths =
      Enum.filter(all_library_paths, &(&1.type in [:series, :mixed]))

    # Fix movies in series libraries
    Enum.each(movies_in_series_libs, fn mismatch ->
      fix_movie_in_series_library(mismatch, movies_compatible_paths)
    end)

    # Fix TV shows in movies libraries
    Enum.each(shows_in_movies_libs, fn mismatch ->
      fix_tv_show_in_movies_library(mismatch, series_compatible_paths)
    end)

    Mix.shell().info("\n✅ All fixes applied.")
  end

  defp fix_movie_in_series_library(mismatch, compatible_paths) do
    media_file = mismatch.media_file
    media_item = mismatch.media_item
    current_library = mismatch.library_path
    absolute_path = MediaFile.absolute_path(media_file)

    # Try to find a compatible library path to move to
    target_library = List.first(compatible_paths)

    cond do
      # No compatible library exists
      is_nil(target_library) ->
        Mix.shell().error("""
        ❌ Cannot fix movie in series library (no compatible library found):
           Title: #{media_item.title} (#{media_item.year})
           File: #{absolute_path}
           Action: Delete the media_file association (file will become orphaned)
        """)

        # Delete the media file association (orphan the file)
        case Library.delete_media_file(media_file) do
          {:ok, _} ->
            Mix.shell().info("   ✓ Media file association deleted")

          {:error, reason} ->
            Mix.shell().error("   ✗ Failed to delete association: #{inspect(reason)}")
        end

      # Same library (library was changed to :mixed or :movies)
      target_library.id == current_library.id ->
        Mix.shell().info("""
        ℹ️  Movie is now in compatible library (no action needed):
           Title: #{media_item.title} (#{media_item.year})
           Library: #{current_library.path} (type: #{current_library.type})
        """)

      # Different library available
      true ->
        Mix.shell().info("""
        🔄 Would move movie to compatible library:
           Title: #{media_item.title} (#{media_item.year})
           From: #{current_library.path} (type: :series)
           To: #{target_library.path} (type: #{target_library.type})
           File: #{absolute_path}
           Note: This task does not move physical files, only orphans the association.
                 Use library scanner to re-import in the correct library.
        """)

        # For now, just orphan the file - let library scanner re-import it
        case Library.delete_media_file(media_file) do
          {:ok, _} ->
            Mix.shell().info("   ✓ Media file association deleted (file orphaned)")

          {:error, reason} ->
            Mix.shell().error("   ✗ Failed to delete association: #{inspect(reason)}")
        end
    end
  end

  defp fix_tv_show_in_movies_library(mismatch, compatible_paths) do
    media_file = mismatch.media_file
    media_item = mismatch.media_item
    episode = mismatch.episode
    current_library = mismatch.library_path
    absolute_path = MediaFile.absolute_path(media_file)

    # Try to find a compatible library path to move to
    target_library = List.first(compatible_paths)

    cond do
      # No compatible library exists
      is_nil(target_library) ->
        Mix.shell().error("""
        ❌ Cannot fix TV show in movies library (no compatible library found):
           Show: #{media_item.title}
           Episode: S#{String.pad_leading("#{episode.season_number}", 2, "0")}E#{String.pad_leading("#{episode.episode_number}", 2, "0")}
           File: #{absolute_path}
           Action: Delete the media_file association (file will become orphaned)
        """)

        # Delete the media file association (orphan the file)
        case Library.delete_media_file(media_file) do
          {:ok, _} ->
            Mix.shell().info("   ✓ Media file association deleted")

          {:error, reason} ->
            Mix.shell().error("   ✗ Failed to delete association: #{inspect(reason)}")
        end

      # Same library (library was changed to :mixed or :series)
      target_library.id == current_library.id ->
        Mix.shell().info("""
        ℹ️  TV show is now in compatible library (no action needed):
           Show: #{media_item.title}
           Episode: S#{String.pad_leading("#{episode.season_number}", 2, "0")}E#{String.pad_leading("#{episode.episode_number}", 2, "0")}
           Library: #{current_library.path} (type: #{current_library.type})
        """)

      # Different library available
      true ->
        Mix.shell().info("""
        🔄 Would move TV episode to compatible library:
           Show: #{media_item.title}
           Episode: S#{String.pad_leading("#{episode.season_number}", 2, "0")}E#{String.pad_leading("#{episode.episode_number}", 2, "0")}
           From: #{current_library.path} (type: :movies)
           To: #{target_library.path} (type: #{target_library.type})
           File: #{absolute_path}
           Note: This task does not move physical files, only orphans the association.
                 Use library scanner to re-import in the correct library.
        """)

        # For now, just orphan the file - let library scanner re-import it
        case Library.delete_media_file(media_file) do
          {:ok, _} ->
            Mix.shell().info("   ✓ Media file association deleted (file orphaned)")

          {:error, reason} ->
            Mix.shell().error("   ✗ Failed to delete association: #{inspect(reason)}")
        end
    end
  end
end
