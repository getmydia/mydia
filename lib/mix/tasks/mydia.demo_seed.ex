defmodule Mix.Tasks.Mydia.DemoSeed do
  @moduledoc """
  Seeds an invented demo library, for website screenshots.

      mix mydia.demo_seed [--base-url URL]

  Writes about 20 movies and 8 shows (every title made up), their episodes,
  media files and playback progress for the first admin, and copies the
  committed AI-generated poster and backdrop images from `assets/demo/art/`
  to `priv/static/images/demo/`. Run it from the repository root. Refuses to
  run unless the database holds no media and every art file is present.

  Items store absolute image URLs. They default to the endpoint's URL, which in
  dev is the self-signed https one; pass `--base-url http://localhost:PORT` when
  the browser that will load them does not trust that certificate.
  """

  use Mix.Task

  @shortdoc "Seed an invented demo library for screenshots"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [base_url: :string])
    Mix.Task.run("app.start")

    case Mydia.Demo.Library.seed(Keyword.take(opts, [:base_url])) do
      {:ok, %{movies: movies, shows: shows, episodes: episodes}} ->
        Mix.shell().info("Seeded #{movies} movies, #{shows} shows, #{episodes} episodes.")

      {:error, :not_empty} ->
        Mix.shell().error("The database already holds media; refusing to seed a demo library.")
        exit({:shutdown, 1})

      {:error, :no_admin_user} ->
        Mix.shell().error("No admin user exists. Create one first (mix mydia.user add).")
        exit({:shutdown, 1})

      {:error, {:art_missing, files}} ->
        Mix.shell().error(
          "Demo artwork missing from assets/demo/art (#{length(files)} files); nothing was written:\n" <>
            Enum.map_join(files, "\n", &("  " <> &1))
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Demo seed failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
