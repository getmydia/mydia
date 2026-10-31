defmodule Mydia.Indexers.Cardigann.Wasm.PrivateTrackerJourneyTest do
  @moduledoc """
  The private-tracker journeys of `Mydia.Indexers.PrivateTrackerJourneyTest`
  on the Prowlarr-based (wasm) engine, against the same invented trackers.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Wasm.{Adapter, Artifact, Engine}
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}
  alias Mydia.PrivateTrackerFixtures, as: Trackers

  @moduletag :cardigann_wasm
  @moduletag timeout: 120_000

  @secrets Trackers.secrets()

  setup do
    :ok = Engine.ensure_started()

    on_exit(fn ->
      Supervisor.terminate_child(Mydia.Supervisor, Engine)
      Supervisor.delete_child(Mydia.Supervisor, Engine)
    end)

    unless Engine.available?() do
      flunk("cardigann.wasm unavailable (#{inspect(Artifact.load())})")
    end

    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    Application.put_env(:mydia, :cardigann_wasm_gate_opts, allow_private_except_link_local: true)

    on_exit(fn ->
      Application.put_env(:mydia, :features, original_features)
      Application.delete_env(:mydia, :cardigann_wasm_gate_opts)
    end)

    {:ok, bypass: Bypass.open()}
  end

  defp config(%{definition: definition}) do
    definition = Repo.get!(CardigannDefinition, definition.id)
    Mydia.Indexers.cardigann_config(definition)
  end

  defp search(tracker), do: Adapter.search(config(tracker), "Fictional", [])

  defp status(%{definition: %{id: id}}), do: Repo.get!(CardigannDefinition, id).health_status

  defp drain(event) do
    receive do
      {:tracker, ^event, _} -> 1 + drain(event)
    after
      0 -> 0
    end
  end

  describe "UNIT3D-style API tracker" do
    test "the API key rides the search as a Bearer header", %{bypass: bypass} do
      tracker = Trackers.start_tracker(bypass, :unit3d, %{"apikey" => @secrets.apikey})

      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Harbor.Lights.2031.1080p.BluRay.x264-INVENTED"
      assert_received {:tracker, :search, %{authorization: "Bearer " <> key}}
      assert key == @secrets.apikey
    end
  end

  describe "Gazelle-style form tracker" do
    setup %{bypass: bypass} do
      tracker =
        Trackers.start_tracker(bypass, :gazelle, %{
          "username" => @secrets.username,
          "password" => @secrets.password
        })

      {:ok, tracker: tracker}
    end

    test "logs in with the CSRF token, stores the session and reuses it", %{tracker: tracker} do
      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Quiet.Orchard.2030.2160p.WEB-DL.DDP5.1-INVENTED"

      assert_received {:tracker, :login, params}
      assert params["auth"] == @secrets.csrf

      assert {:ok, %{cookies: cookies}} = CardigannAuth.get_stored_session(tracker.definition.id)
      assert Enum.any?(cookies, &String.starts_with?(&1, "session="))

      assert {:ok, [_]} = search(tracker)
      assert drain(:login) == 0
    end

    test "an expired session logs in again exactly once", %{tracker: tracker} do
      assert {:ok, [_]} = search(tracker)
      drain(:login)

      Trackers.expire_sessions(tracker)

      assert {:ok, [_]} = search(tracker)
      assert drain(:login) == 1
    end
  end

  describe "captcha and 2FA tracker" do
    setup %{bypass: bypass} do
      tracker =
        Trackers.start_tracker(bypass, :captcha, %{
          "username" => @secrets.username,
          "password" => @secrets.password
        })

      {:ok, tracker: tracker}
    end

    test "a session from the Indexers page login is reused", %{tracker: tracker} do
      built_in_login(tracker)

      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Salt.Meadow.S02E04.1080p.WEB-DL-INVENTED"
      assert drain(:login) == 0
    end

    test "a search with no session parks the indexer in needs_login", %{tracker: tracker} do
      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert status(tracker) == "needs_login"
      assert drain(:login) == 0
    end

    test "a captcha on re-login moves the indexer to needs_login", %{tracker: tracker} do
      built_in_login(tracker)
      assert {:ok, [_]} = search(tracker)

      Trackers.expire_sessions(tracker)

      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert status(tracker) == "needs_login"
      assert drain(:login) == 0
    end
  end

  describe "captcha tracker, a person logs in while a search fails" do
    test "the search retries once on the new session instead of reporting no results", %{
      bypass: bypass
    } do
      tracker =
        Trackers.start_tracker(bypass, :captcha, %{
          "username" => @secrets.username,
          "password" => @secrets.password
        })

      built_in_login(tracker)
      {:ok, %{cookies: valid}} = CardigannAuth.get_stored_session(tracker.definition.id)
      {:ok, _} = CardigannAuth.store_session(tracker.definition.id, ["c_secure_uid=stale"])

      # The guest's login stops at the captcha; meanwhile the Indexers page stores a session.
      id = tracker.definition.id

      Bypass.stub(bypass, "GET", "/image.php", fn conn ->
        {:ok, _} = CardigannAuth.store_session(id, valid)
        Plug.Conn.resp(conn, 200, Trackers.captcha_png())
      end)

      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Salt.Meadow.S02E04.1080p.WEB-DL-INVENTED"
      assert status(tracker) == "healthy"
    end
  end

  describe "captcha tracker with templated login paths" do
    test "a captcha on re-login still parks the indexer", %{bypass: bypass} do
      tracker =
        Trackers.start_tracker(bypass, :captcha, %{
          "username" => @secrets.username,
          "password" => @secrets.password
        })

      yaml =
        tracker.definition.definition
        |> String.replace(
          "path: login.php",
          ~s(path: "{{ .Config.sitelink }}login.php")
        )
        |> String.replace(
          "submitpath: takelogin.php",
          ~s(submitpath: "{{ .Config.sitelink }}takelogin.php")
        )

      definition =
        tracker.definition |> Ecto.Changeset.change(definition: yaml) |> Repo.update!()

      tracker = %{tracker | definition: definition}

      built_in_login(tracker)
      assert {:ok, [_]} = search(tracker)

      Trackers.expire_sessions(tracker)

      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert status(tracker) == "needs_login"
    end
  end

  # What the Indexers page does: the built-in login, whatever the engine.
  defp built_in_login(%{definition: definition}) do
    definition = Repo.get!(CardigannDefinition, definition.id)
    {:ok, parsed} = Mydia.Indexers.CardigannParser.parse_definition(definition.definition)
    {:needs_input, challenge} = Mydia.Indexers.Cardigann.Login.begin(parsed, definition)

    {:ok, session} =
      Mydia.Indexers.Cardigann.Login.complete(challenge, %{
        "captcha" => @secrets.captcha,
        "2facode" => @secrets.twofa
      })

    Mydia.Indexers.Cardigann.SessionManager.store(definition, session)
    drain(:login)
    drain(:login_page)
    drain(:captcha_image)
  end
end
