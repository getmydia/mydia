defmodule Mydia.Indexers.Cardigann.ParityTest do
  # Replays the committed, scrubbed captures through both Cardigann engines and
  # holds the native engine to the wasm engine (Prowlarr's own code) field by
  # field. See lib/mydia/indexers/README.md, "Cardigann parity oracle".
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Cardigann.Parity.{Capture, Ratchet, Runner}
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @moduletag :cardigann_wasm
  @moduletag timeout: 300_000
  @root Path.expand("../../../fixtures/cardigann/parity", __DIR__)
  @ratchet Path.join(@root, "known_divergences.exs")

  # One {definition, query} per committed capture directory.
  @captures (for def_dir <- Path.wildcard(Path.join(@root, "*")),
                 File.regular?(Path.join(def_dir, "definition.yml")),
                 exchanges <- Path.wildcard(Path.join(def_dir, "*/exchanges.json")) do
               {Path.basename(def_dir), exchanges |> Path.dirname() |> Path.basename()}
             end)

  setup do
    # Clean up only an engine this test started, never the application's own.
    owned? = is_nil(Process.whereis(Engine))
    :ok = Engine.ensure_started()

    # The application starts the engine only under CARDIGANN_ENGINE=prowlarr.
    if owned? do
      on_exit(fn ->
        Supervisor.terminate_child(Mydia.Supervisor, Engine)
        Supervisor.delete_child(Mydia.Supervisor, Engine)
      end)
    end

    unless Engine.available?() do
      flunk(
        "cardigann.wasm unavailable (#{inspect(Artifact.load())}): " <>
          "run mix mydia.cardigann_guest fetch or native/cardigann_guest/build.sh wasm"
      )
    end

    original = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    on_exit(fn -> Application.put_env(:mydia, :features, original) end)

    :ok
  end

  # The committed seed. Changing it is a deliberate act: update this list, the
  # ratchet and the table in lib/mydia/indexers/README.md together.
  @expected [
    {"bigfangroup", "movie"},
    {"bigfangroup", "rss"},
    {"blueroms", "generic"},
    {"blueroms", "rss"},
    {"dmhy", "movie"},
    {"dmhy", "rss"},
    {"linuxtracker", "generic"},
    {"linuxtracker", "rss"},
    {"mikan", "rss"},
    {"mikan", "tv"},
    {"nekobt", "movie"},
    {"nekobt", "rss"},
    {"nyaasi", "movie"},
    {"nyaasi", "rss"},
    {"pctorrent", "generic"},
    {"pctorrent", "rss"},
    {"yts", "movie"},
    {"yts", "rss"}
  ]

  test "the seed set is exactly the expected captures" do
    assert Enum.sort(@captures) == @expected
  end

  # yts is movie-capable, so the corpus records it with the movie term "1080p",
  # which matches no YTS title. The capture still checks that both engines
  # agree on an empty answer, but it covers none of yts's row parsing; rss does.
  # If a re-record ever returns rows, update this and the README table.
  test "yts/movie is known to be an empty answer" do
    body = File.read!(Path.join(@root, "yts/movie/001.json"))
    assert Jason.decode!(body) == %{"data" => %{"movie_count" => 0}}
  end

  test "every ratchet entry names a committed capture" do
    captures = MapSet.new(@captures)

    orphans =
      for entry <- Ratchet.load!(@ratchet),
          {entry.definition, Atom.to_string(entry.query)} not in captures,
          do: entry

    assert orphans == [], "ratchet entries with no capture: #{inspect(orphans)}"
  end

  # One test per capture, so a failure names the capture it came from.
  for {definition, query} <- @captures do
    test "native agrees with wasm on #{definition}/#{query}, up to the ratchet" do
      definition = unquote(definition)
      query = unquote(query)
      def_dir = Path.join(@root, definition)

      :ok =
        Runner.prepare_definition(definition, File.read!(Path.join(def_dir, "definition.yml")))

      %{divergences: divergences} =
        def_dir |> Path.join(query) |> Capture.read!() |> Runner.replay() |> Runner.compare()

      entries =
        for entry <- Ratchet.load!(@ratchet),
            entry.definition == definition and Atom.to_string(entry.query) == query,
            do: entry

      case Ratchet.check(divergences, entries) do
        :ok -> :ok
        {:error, failure} -> flunk(Ratchet.format_failure(failure))
      end
    end
  end
end
