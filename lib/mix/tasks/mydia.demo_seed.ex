defmodule Mix.Tasks.Mydia.DemoSeed do
  @moduledoc """
  Seeds a demo library from a local title list, for website screenshots.

      mix mydia.demo_seed [--titles PATH]

  The list defaults to `.demo-titles.local` at the repository root. It is
  git-ignored, so titles never reach the repository. One entry per line,
  `movie <tmdb_id>` or `tv <tmdb_id>`, with `#` comments:

      movie 12345   # name it here
      tv 67890

  Each entry is fetched through the metadata relay, then written with its
  seasons, episodes, media file rows and playback progress for the first admin.
  Refuses to run unless the database holds no media, and writes nothing if any
  fetch fails.
  """

  use Mix.Task

  @shortdoc "Seed a demo library from a local TMDB id list, for screenshots"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [titles: :string])
    Mix.Task.run("app.start")

    seed_opts =
      case opts[:titles] do
        nil -> []
        path -> [titles: Path.expand(path)]
      end

    case Mydia.Demo.Library.seed(seed_opts) do
      {:ok, %{movies: movies, shows: shows, episodes: episodes}} ->
        Mix.shell().info("Seeded #{movies} movies, #{shows} shows, #{episodes} episodes.")

      {:error, reason} ->
        Mix.shell().error(message(reason))
        exit({:shutdown, 1})
    end
  end

  defp message(:not_empty),
    do: "The database already holds media; refusing to seed a demo library."

  defp message(:no_admin_user),
    do: "No admin user exists. Create one first (mix mydia.user add)."

  defp message(:no_titles), do: "The title list holds no entries."

  defp message({:titles_file, path, reason}),
    do:
      "Cannot read the title list #{path}: #{:file.format_error(reason)}. " <>
        "Create it with one `movie <tmdb_id>` or `tv <tmdb_id>` per line."

  defp message({:invalid_line, number, line}),
    do: "Title list line #{number} is not `movie <id>` or `tv <id>`: #{inspect(line)}"

  defp message({:fetch_failed, {kind, id}, reason}),
    do: "Fetching #{kind} #{id} failed; nothing was written: #{inspect(reason)}"

  defp message(reason), do: "Demo seed failed: #{inspect(reason)}"
end
