defmodule Mix.Tasks.Mydia.MigrateTvdbIds do
  @moduledoc """
  Discovers TVDB IDs for TV shows that only have a TMDB ID.

  After migrating from TMDB to TVDB as the preferred metadata provider for
  TV shows, existing series may only have `tmdb_id` set. This task searches
  TVDB by title and stores the discovered `tvdb_id` so that future metadata
  refreshes use the preferred provider.

  ## Usage

      mix mydia.migrate_tvdb_ids

  ## Options

      --dry-run  - Show what would be done without making changes
      --limit N  - Only process the first N shows

  ## Examples

      # Show which shows need migration
      mix mydia.migrate_tvdb_ids --dry-run

      # Migrate one show as a test
      mix mydia.migrate_tvdb_ids --limit 1

      # Migrate all shows
      mix mydia.migrate_tvdb_ids
  """

  use Mix.Task
  require Logger

  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  import Ecto.Query

  @shortdoc "Discovers TVDB IDs for TMDB-only TV shows"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [dry_run: :boolean, limit: :integer],
        aliases: [d: :dry_run, l: :limit]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)

    if dry_run do
      Mix.shell().info("DRY RUN MODE - No changes will be made\n")
    end

    discover_tvdb_ids(dry_run, limit)
  end

  defp discover_tvdb_ids(dry_run, limit) do
    query =
      from mi in MediaItem,
        where: mi.type == "tv_show",
        where: not is_nil(mi.tmdb_id),
        where: is_nil(mi.tvdb_id),
        order_by: mi.title

    query =
      if limit do
        from mi in query, limit: ^limit
      else
        query
      end

    shows = Repo.all(query)

    Mix.shell().info("Found #{length(shows)} TV show(s) with TMDB ID but no TVDB ID\n")

    if shows == [] do
      Mix.shell().info("Nothing to do.")
      :ok
    else
      results =
        shows
        |> Enum.map(fn show ->
          result = process_show(show, dry_run)

          unless dry_run do
            # Rate limit between API requests
            Process.sleep(500)
          end

          result
        end)
        |> Enum.group_by(fn {status, _} -> status end)

      print_summary(results, dry_run)
    end
  end

  defp process_show(show, dry_run) do
    if dry_run do
      Mix.shell().info("  #{show.title} (TMDB ID: #{show.tmdb_id})")
      {:would_migrate, %{title: show.title, tmdb_id: show.tmdb_id}}
    else
      Mix.shell().info("Processing: #{show.title} (TMDB ID: #{show.tmdb_id})...")

      case Media.recover_provider_id_by_title(show, :tv_show) do
        {:ok, _provider_id, updated_item} when not is_nil(updated_item.tvdb_id) ->
          Mix.shell().info("  -> Discovered TVDB ID: #{updated_item.tvdb_id} for #{show.title}")

          {:discovered, %{title: show.title, tvdb_id: updated_item.tvdb_id}}

        {:ok, _provider_id, _updated_item} ->
          Mix.shell().info("  -> No TVDB match found for #{show.title}")
          {:no_match, %{title: show.title}}

        {:error, reason} ->
          Mix.shell().info("  -> Failed for #{show.title}: #{inspect(reason)}")
          {:error, %{title: show.title, reason: reason}}
      end
    end
  end

  defp print_summary(results, dry_run) do
    Mix.shell().info("\nSummary:")
    Mix.shell().info(String.duplicate("=", 50))

    if dry_run do
      would_migrate = Map.get(results, :would_migrate, [])
      Mix.shell().info("Shows needing TVDB discovery: #{length(would_migrate)}")
    else
      discovered = Map.get(results, :discovered, [])
      no_match = Map.get(results, :no_match, [])
      errors = Map.get(results, :error, [])

      Mix.shell().info("Discovered: #{length(discovered)}")
      Mix.shell().info("No match:   #{length(no_match)}")

      if errors != [] do
        Mix.shell().error("Errors:     #{length(errors)}")
      end
    end

    Mix.shell().info(String.duplicate("=", 50))

    if dry_run do
      Mix.shell().info("\nRun without --dry-run to perform the migration")
    end
  end
end
