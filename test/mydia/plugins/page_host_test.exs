defmodule Mydia.Plugins.PageHostTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Playback
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "plugins", "page_fixture.wasm"])
  @slug "page-fixture"

  @all_grants %{
    "surfaces:page" => [],
    "data:search" => [],
    "data:read" => ["collection", "media_item", "library_item", "playback_progress"],
    "surfaces:write" => ["collections:write", "collections:favorite"]
  }

  setup do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Page Fixture",
        version: "0.0.0",
        source_url: "test",
        manifest: %{"slug" => @slug, "name" => "Page Fixture", "version" => "0.0.0"},
        granted_capabilities: %{},
        enabled: true
      })

    register(@all_grants)

    {:ok, _} =
      Host.start_plugin(@slug, File.read!(@fixture), imports: HostFunctions.imports_for(@slug))

    on_exit(fn ->
      Host.stop_plugin(@slug)
      Registry.unregister(@slug)
    end)

    {:ok, user: user_fixture()}
  end

  defp register(granted) do
    Registry.register(@slug, %Plugin{
      slug: @slug,
      name: "Page Fixture",
      enabled: true,
      granted_capabilities: granted
    })
  end

  defp call(user, path, body, session \\ "s1") do
    payload = %{
      "method" => "POST",
      "path" => path,
      "query" => "",
      "headers" => [{"content-type", "application/json"}],
      "body" => Jason.encode!(body),
      "config" => %{"greeting" => "hi"}
    }

    Host.call(@slug, "on-http", payload,
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: session
    )
  end

  defp call_json(user, path, body) do
    assert {:ok, %{body: resp}} = call(user, path, body)
    Jason.decode!(resp)
  end

  test "on-http receives the host-verified user and returns the response", %{user: user} do
    assert {:ok, %{status: 200, body: body, headers: headers}} = call(user, "/echo", %{"x" => 1})
    decoded = Jason.decode!(body)
    assert decoded["user_id"] == user.id
    assert decoded["role"] == user.role
    assert decoded["session_id"] == "s1"
    assert Jason.decode!(decoded["config"]) == %{"greeting" => "hi"}
    assert {"content-type", "application/json"} in headers
  end

  test "headers given as [k, v] lists or malformed entries do not raise", %{user: user} do
    payload = %{
      "method" => "POST",
      "path" => "/echo",
      "query" => "",
      "headers" => [["content-type", "application/json"], ["only-a-name"], "junk", 7],
      "body" => Jason.encode!(%{"x" => 1}),
      "config" => %{}
    }

    assert {:ok, %{status: 200}} =
             Host.call(@slug, "on-http", payload,
               handler: :on_http,
               acting_user_id: user.id,
               role: user.role,
               session_id: "s1"
             )

    assert {:ok, %{status: 200}} =
             Host.call(@slug, "on-http", Map.put(payload, "headers", %{"accept" => "x"}),
               handler: :on_http,
               acting_user_id: user.id,
               role: user.role,
               session_id: "s1"
             )
  end

  test "a caller cannot smuggle a different user through the payload", %{user: user} do
    other = user_fixture()

    payload = %{
      "method" => "GET",
      "path" => "/echo",
      "query" => "",
      "headers" => [],
      "body" => nil,
      "config" => %{},
      "user_id" => other.id,
      "role" => "admin",
      "session_id" => "forged"
    }

    assert {:ok, %{body: body}} =
             Host.call(@slug, "on-http", payload,
               handler: :on_http,
               acting_user_id: user.id,
               role: user.role,
               session_id: "real"
             )

    decoded = Jason.decode!(body)
    assert decoded["user_id"] == user.id
    assert decoded["role"] == user.role
    assert decoded["session_id"] == "real"
  end

  test "an ungranted write comes back pending, a granted one executes", %{user: user} do
    assert %{"outcome" => "pending", "id" => _} =
             call_json(user, "/call/collection-create", %{"name" => "Rainy Sundays"})

    :ok = Grants.grant(@slug, user.id, "collections:write", "session", "s1")

    assert %{"outcome" => "done"} =
             call_json(user, "/call/collection-create", %{"name" => "Quiet Nights"})

    assert Enum.any?(Collections.list_collections(user), &(&1.name == "Quiet Nights"))
  end

  test "the collection namespace lists through data-list", %{user: user} do
    {:ok, _} = Collections.create_collection(user, %{name: "Mine", type: "manual"})
    assert %{"count" => n} = call_json(user, "/call/data-list", %{"namespace" => "collection"})
    assert n >= 1
  end

  test "library search runs as the user", %{user: user} do
    media_item_fixture(%{title: "Harbor of Glass", type: "movie"})
    body = call_json(user, "/call/search", %{"kind" => "library", "query" => "Harbor"})
    assert "Harbor of Glass" in body["titles"]
  end

  describe "data-list inside on-http acts as the user" do
    test "media_item and library_item honor the user's access restriction", %{user: _} do
      restricted = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
      admin = admin_user_fixture()

      categorized_media_item_fixture(%{title: "Allowed Cartoon", type: "movie"}, :cartoon_movie)
      categorized_media_item_fixture(%{title: "Other Feature", type: "movie"}, :movie)

      for namespace <- ["media_item", "library_item"] do
        assert %{"count" => 1} =
                 call_json(restricted, "/call/data-list", %{"namespace" => namespace})

        assert %{"count" => 2} = call_json(admin, "/call/data-list", %{"namespace" => namespace})
      end
    end

    test "outside a page the plugin still sees the whole instance" do
      restricted = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
      categorized_media_item_fixture(%{title: "Allowed Cartoon", type: "movie"}, :cartoon_movie)
      categorized_media_item_fixture(%{title: "Other Feature", type: "movie"}, :movie)

      {:ok, plugin} = Mydia.Plugins.get_plugin(@slug)

      assert {:ok, %{items: items}} = HostFunctions.data_list(plugin, %{namespace: "media_item"})
      assert length(items) == 2

      # A page context for the restricted user narrows the same call.
      ctx = %{handler: :on_http, acting_user_id: restricted.id}

      assert {:ok, %{items: [_one]}} =
               HostFunctions.data_list(plugin, %{namespace: "media_item"}, ctx)
    end

    test "playback_progress returns the acting user's rows, connected or not", %{user: user} do
      other = user_fixture()
      movie = media_item_fixture(%{title: "The Tin Orchard", type: "movie"})

      for u <- [user, other] do
        {:ok, _} =
          Playback.save_progress(u.id, [media_item_id: movie.id], %{
            position_seconds: 95,
            duration_seconds: 100
          })
      end

      # Neither user is connected to the plugin, so a non-page read sees nothing.
      {:ok, plugin} = Mydia.Plugins.get_plugin(@slug)

      assert {:ok, %{items: []}} =
               HostFunctions.data_list(plugin, %{namespace: "playback_progress"})

      assert %{"count" => 1} =
               call_json(user, "/call/data-list", %{"namespace" => "playback_progress"})
    end
  end

  describe "capability narrowing" do
    test "a search without data:search is denied", %{user: user} do
      register(Map.delete(@all_grants, "data:search"))

      assert {:ok, %{status: 500, body: body}} =
               call(user, "/call/search", %{"kind" => "library", "query" => "x"})

      assert body =~ "Denied"
    end

    test "a write without the matching surface grant is denied and creates nothing", %{user: user} do
      register(%{"surfaces:page" => [], "surfaces:write" => ["collections:favorite"]})

      assert {:ok, %{status: 500, body: body}} =
               call(user, "/call/collection-create", %{"name" => "Nope"})

      assert body =~ "Denied"
      refute Enum.any?(Collections.list_collections(user), &(&1.name == "Nope"))
    end

    test "a data namespace that is not granted is denied", %{user: user} do
      register(Map.put(@all_grants, "data:read", ["collection"]))

      assert {:ok, %{status: 500, body: body}} =
               call(user, "/call/data-list", %{"namespace" => "media_item"})

      assert body =~ "Denied"
    end

    test "older host namespaces do not link the page functions" do
      builder = HostFunctions.imports_for(@slug)
      imports = builder.(%{slug: @slug, invocation_id: "i", test_run: false, handler: :on_event})

      page_funcs =
        ~w(search media-add collection-create collection-update collection-add-items collection-remove-items mark-watched-state add-favorite)

      current = imports["mydia:plugin/host@1.4.0"]
      assert Enum.all?(page_funcs, &Map.has_key?(current, &1))

      for older <- ["1.3.0", "1.2.0", "1.1.0"] do
        funcs = imports["mydia:plugin/host@#{older}"]
        assert funcs != nil

        refute Enum.any?(page_funcs, &Map.has_key?(funcs, &1)),
               "host@#{older} links a page function"
      end

      assert Map.has_key?(imports["mydia:plugin/host@1.3.0"], "ensure-favorite")
    end

    test "page host functions are refused outside on-http" do
      assert {:error, %{type: :guest_error, message: msg}} =
               Host.call(@slug, "handle", %{"event" => "page-write", "metadata" => %{}})

      assert msg =~ "interactive"
    end
  end

  describe "page locking and slots" do
    alias Mydia.Plugins.SingleFlight

    defp call_opts(user, path, body, extra) do
      payload = %{
        "method" => "POST",
        "path" => path,
        "query" => "",
        "headers" => [],
        "body" => Jason.encode!(body),
        "config" => %{}
      }

      Host.call(
        @slug,
        "on-http",
        payload,
        [handler: :on_http, acting_user_id: user.id, role: user.role, session_id: "s1"] ++ extra
      )
    end

    defp sleeper(user, ms), do: Task.async(fn -> call(user, "/call/sleep", %{"ms" => ms}) end)

    # Polls until `key` is held by some process (a probe that wins the lock
    # releases it and tries again).
    defp await_held(key, tries \\ 500) do
      case SingleFlight.acquire(key, :skip) do
        :busy ->
          :ok

        :ok ->
          SingleFlight.release(key)

          if tries == 0 do
            flunk("#{key} was never taken")
          else
            Process.sleep(10)
            await_held(key, tries - 1)
          end
      end
    end

    defp stop_sleepers(tasks), do: Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    test "a user's slow page call does not hold up another user" do
      a = user_fixture()
      b = user_fixture()

      a_task = sleeper(a, 3_000)
      await_held("#{@slug}:user:#{a.id}")

      # B is served while A's guest is still inside its call.
      assert {:ok, %{status: 200}} = call(b, "/echo", %{})
      assert Task.yield(a_task, 0) == nil

      stop_sleepers([a_task])
    end

    test "one user's page calls serialize, and the wait is bounded" do
      a = user_fixture()
      first = sleeper(a, 3_000)
      await_held("#{@slug}:user:#{a.id}")

      assert {:error, %{type: :busy}} = call_opts(a, "/echo", %{}, page_wait_ms: 100)
      stop_sleepers([first])
    end

    test "a page call with no acting user is refused" do
      assert {:error, %{type: :invalid_request}} =
               Host.call(@slug, "on-http", %{"method" => "GET", "path" => "/echo"},
                 handler: :on_http,
                 role: "user",
                 session_id: "s1"
               )
    end

    test "saturated page slots leave the pool free for events and answer busy to more pages" do
      Host.stop_plugin(@slug)

      {:ok, _} =
        Host.start_plugin(@slug, File.read!(@fixture),
          imports: HostFunctions.imports_for(@slug),
          pool_size: 3
        )

      [a, b, c] = [user_fixture(), user_fixture(), user_fixture()]
      tasks = [sleeper(a, 3_000), sleeper(b, 3_000)]
      await_held("#{@slug}:page-slot:0")
      await_held("#{@slug}:page-slot:1")

      assert {:ok, _} = Host.call(@slug, "handle", %{"event" => "noop", "metadata" => %{}})
      assert {:error, %{type: :busy}} = call_opts(c, "/echo", %{}, page_wait_ms: 100)

      stop_sleepers(tasks)
    end

    test "a page call that times out releases the user's lock", %{user: user} do
      assert {:error, %{type: :timeout}} =
               call_opts(user, "/call/sleep", %{"ms" => 5_000}, timeout: 300)

      assert {:ok, %{status: 200}} = call_opts(user, "/echo", %{}, page_wait_ms: 500)
    end
  end
end
