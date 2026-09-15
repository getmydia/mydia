defmodule Mydia.Perf.KeysTest do
  use MydiaWeb.ConnCase

  import Mydia.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Mydia.Perf.Keys

  @doc false
  def forward(event, _measurements, metadata, test_pid) do
    send(test_pid, {:captured, event, metadata})
  end

  # Forwards every metadata map emitted for `event` to this test process.
  defp capture(event) do
    handler_id = {__MODULE__, event, make_ref()}
    :ok = :telemetry.attach(handler_id, event, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Applies `fun` to every captured metadata map already in the mailbox.
  defp drain(fun, acc \\ []) do
    receive do
      {:captured, _event, metadata} -> drain(fun, [fun.(metadata) | acc])
    after
      0 -> acc
    end
  end

  describe "LiveView keys" do
    test "a real mount is keyed by view, dead and connected", %{conn: conn} do
      capture([:phoenix, :live_view, :mount, :stop])

      {:ok, _view, _html} = live(log_in_user(conn, user_fixture()), ~p"/movies")

      keys = drain(&Keys.live_view/1)
      assert %{view: "MydiaWeb.MediaLive.Index", connected: false} in keys
      assert %{view: "MydiaWeb.MediaLive.Index", connected: true} in keys
    end

    test "events and renders are keyed from a real socket", %{conn: conn} do
      capture([:phoenix, :live_view, :mount, :stop])

      {:ok, _view, _html} = live(log_in_user(conn, user_fixture()), ~p"/movies")

      assert_received {:captured, _, %{socket: %{view: MydiaWeb.MediaLive.Index} = socket}}

      assert Keys.live_view_event(%{socket: socket, event: "toggle_monitored", params: %{}}) ==
               %{view: "MydiaWeb.MediaLive.Index", event: "toggle_monitored"}

      assert Keys.render(%{socket: socket, force?: false, changed?: true}) ==
               %{view: "MydiaWeb.MediaLive.Index", component: "none"}

      assert Keys.render(%{socket: socket, component: MydiaWeb.ExampleComponent}) ==
               %{view: "MydiaWeb.MediaLive.Index", component: "MydiaWeb.ExampleComponent"}
    end

    test "component events are keyed by component and event" do
      assert Keys.component_event(%{
               socket: nil,
               component: MydiaWeb.ExampleComponent,
               event: "save",
               params: %{}
             }) == %{component: "MydiaWeb.ExampleComponent", event: "save"}
    end
  end

  describe "graphql/1" do
    test "a real named operation is keyed by name and context source" do
      capture([:absinthe, :execute, :operation, :stop])

      {:ok, _} =
        Absinthe.run("query Probe { __typename }", MydiaWeb.Schema, context: %{source: :p2p})

      assert %{operation: "Probe", source: "p2p"} in drain(&Keys.graphql/1)
    end

    test "an unnamed operation without a source" do
      capture([:absinthe, :execute, :operation, :stop])

      {:ok, _} = Absinthe.run("{ __typename }", MydiaWeb.Schema)

      assert %{operation: "anonymous", source: "unknown"} in drain(&Keys.graphql/1)
    end
  end

  describe "query/1" do
    test "a real query is keyed by its first application frame and table" do
      capture([:mydia, :repo, :query])

      {:ok, _count} = Mydia.PerfQueryProbe.count_users()

      assert %{caller: "Mydia.PerfQueryProbe.count_users/0", source: "users"} in drain(
               &Keys.query/1
             )
    end

    test "skips Mydia.Repo and library frames, and names anonymous functions by their parent" do
      stacktrace = [
        {Ecto.Repo.Supervisor, :tuplet, 2, [file: ~c"lib/ecto/repo/supervisor.ex", line: 185]},
        {Mydia.Repo, :all, 2, []},
        {Mydia.Media, :"-list_media_items/1-fun-0-", 1, [file: ~c"lib/mydia/media.ex", line: 40]},
        {MydiaWeb.MediaLive.Index, :load_media_items, 2, []}
      ]

      assert Keys.query(%{stacktrace: stacktrace, source: "media_items"}) ==
               %{caller: "Mydia.Media.list_media_items/1", source: "media_items"}
    end

    test "a frame that carries its arguments instead of an arity" do
      assert Keys.caller([{MydiaWeb.Router, :call, [:conn, :opts], []}]) ==
               "MydiaWeb.Router.call/2"
    end

    test "raw SQL with no stacktrace" do
      assert Keys.query(%{stacktrace: nil, source: nil}) == %{caller: "unknown", source: "none"}
    end

    test "only library frames falls back to the first one outside Ecto and DBConnection" do
      stacktrace = [
        {Ecto.Repo.Supervisor, :tuplet, 2, []},
        {Mydia.Repo, :all, 2, []},
        {DBConnection, :run, 3, []},
        {Oban.Engines.Basic, :fetch_jobs, 3, []},
        {:gen_server, :handle_msg, 6, []}
      ]

      assert Keys.caller(stacktrace) == "Oban.Engines.Basic.fetch_jobs/3"
    end

    test "an application frame after a library frame still wins" do
      stacktrace = [
        {Ecto.Repo.Supervisor, :tuplet, 2, []},
        {Oban.Repo, :all, 3, []},
        {Mydia.Jobs.ExampleWorker, :perform, 1, []}
      ]

      assert Keys.caller(stacktrace) == "Mydia.Jobs.ExampleWorker.perform/1"
    end

    test "only Ecto, DBConnection, Mydia.Repo and Erlang frames returns unknown" do
      stacktrace = [
        {Ecto.Repo.Supervisor, :tuplet, 2, []},
        {Mydia.Repo, :all, 2, []},
        {DBConnection, :run, 3, []},
        {:gen_server, :handle_msg, 6, []},
        {:proc_lib, :init_p_do_apply, 3, []}
      ]

      assert Keys.caller(stacktrace) == "unknown"
    end

    test "an anonymous library frame is keyed by its enclosing function" do
      stacktrace = [{Oban.Queue.Producer, :"-dispatch/1-fun-0-", 0, []}]

      assert Keys.caller(stacktrace) == "Oban.Queue.Producer.dispatch/1"
    end
  end

  describe "route, Oban and p2p keys" do
    test "route/1 uses the route pattern" do
      assert Keys.route(%{route: "/media/:id", plug: MydiaWeb.PageController}) ==
               %{route: "/media/:id"}
    end

    test "oban_job/1 uses the worker and the final state" do
      metadata = %{
        conf: nil,
        job: %Oban.Job{worker: "Mydia.Jobs.ExampleWorker"},
        state: :success,
        result: :ok
      }

      assert Keys.oban_job(metadata) == %{worker: "Mydia.Jobs.ExampleWorker", state: "success"}
    end

    test "oban_job/1 keys an exception by its state" do
      metadata = %{
        conf: nil,
        job: %Oban.Job{worker: "Mydia.Jobs.ExampleWorker"},
        state: :failure,
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        result: nil,
        stacktrace: []
      }

      assert Keys.oban_job(metadata) == %{worker: "Mydia.Jobs.ExampleWorker", state: "failure"}
    end

    test "p2p_request/1 uses the kind" do
      assert Keys.p2p_request(%{kind: "graphql"}) == %{kind: "graphql"}
    end
  end

  describe "unrecognised shapes" do
    for fun <- [
          :live_view,
          :live_view_event,
          :render,
          :component_event,
          :route,
          :graphql,
          :query,
          :oban_job,
          :p2p_request
        ] do
      test "#{fun}/1 never raises" do
        inputs = [%{}, nil, :garbage, %{socket: :nope, blueprint: :nope, stacktrace: :nope}]

        for input <- inputs do
          result = apply(Keys, unquote(fun), [input])
          assert is_map(result)
          assert Enum.all?(Map.values(result), &(&1 in ["unknown", "none"]))
        end
      end
    end
  end
end
