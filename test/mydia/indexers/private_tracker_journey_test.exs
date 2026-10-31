defmodule Mydia.Indexers.PrivateTrackerJourneyTest do
  @moduledoc """
  Whole private-tracker journeys on the built-in Cardigann engine, against the
  three invented trackers in `Mydia.PrivateTrackerFixtures`: configure, log in,
  search, grab, and a session that expires partway through.
  """
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.Cardigann, as: Adapter
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition}
  alias Mydia.PrivateTrackerFixtures, as: Trackers

  @secrets Trackers.secrets()

  setup do
    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    on_exit(fn -> Application.put_env(:mydia, :features, original_features) end)

    {:ok, bypass: Bypass.open()}
  end

  defp configure(%{definition: definition} = tracker, config) do
    {:ok, definition} = Indexers.configure_cardigann_definition(definition, config)
    %{tracker | definition: definition}
  end

  defp search(%{definition: definition}, query \\ "Fictional") do
    definition = Repo.get!(CardigannDefinition, definition.id)
    Adapter.search(Indexers.cardigann_config(definition), query, [])
  end

  defp status(%{definition: %{id: id}}), do: Repo.get!(CardigannDefinition, id).health_status

  defp drain(event) do
    receive do
      {:tracker, ^event, _} -> 1 + drain(event)
    after
      0 -> 0
    end
  end

  describe "UNIT3D-style API tracker" do
    test "the API key rides every search as a Bearer header", %{bypass: bypass} do
      tracker =
        bypass |> Trackers.start_tracker(:unit3d) |> configure(%{"apikey" => @secrets.apikey})

      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Harbor.Lights.2031.1080p.BluRay.x264-INVENTED"
      assert result.seeders == 42
      assert result.download_url =~ "/torrent/download/101."

      assert_received {:tracker, :search, %{authorization: "Bearer " <> key}}
      assert key == @secrets.apikey
    end

    test "a wrong API key is an authentication error, not an empty result", %{bypass: bypass} do
      tracker = bypass |> Trackers.start_tracker(:unit3d) |> configure(%{"apikey" => "wrong"})

      assert {:error, %Error{type: :authentication_failed}} = search(tracker)
      assert drain(:search) == 0
    end
  end

  describe "Gazelle-style form tracker" do
    setup %{bypass: bypass} do
      tracker =
        bypass
        |> Trackers.start_tracker(:gazelle)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      {:ok, tracker: tracker}
    end

    test "logs in once with the CSRF token, then reuses the session", %{tracker: tracker} do
      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Quiet.Orchard.2030.2160p.WEB-DL.DDP5.1-INVENTED"

      assert_received {:tracker, :login, params}
      assert params["auth"] == @secrets.csrf
      assert params["username"] == @secrets.username
      assert params["keeplogged"] == "1"

      assert {:ok, %{cookies: cookies}} = CardigannAuth.get_stored_session(tracker.definition.id)
      assert Enum.any?(cookies, &String.starts_with?(&1, "session="))

      assert {:ok, [_]} = search(tracker)
      assert drain(:login) == 0
      assert drain(:search) == 2
    end

    test "an expired session logs in again exactly once", %{tracker: tracker} do
      assert {:ok, [_]} = search(tracker)
      drain(:login)
      drain(:search)

      Trackers.expire_sessions(tracker)

      assert {:ok, [_]} = search(tracker)
      assert drain(:login) == 1
      # The rejected search and its retry.
      assert drain(:search) == 2
      assert status(tracker) != "needs_login"
    end

    test "a wrong password is an authentication error", %{tracker: tracker} do
      tracker = configure(tracker, %{"username" => @secrets.username, "password" => "nope"})

      assert {:error, %Error{type: :authentication_failed}} = search(tracker)
      assert drain(:search) == 0
    end
  end

  describe "captcha and 2FA tracker" do
    setup %{bypass: bypass} do
      tracker =
        bypass
        |> Trackers.start_tracker(:captcha)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      {:ok, tracker: tracker}
    end

    test "a search with no session parks the indexer in needs_login", %{tracker: tracker} do
      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert status(tracker) == "needs_login"
      assert drain(:login) == 0
      assert drain(:search) == 0

      # Skipped from now on, without a request.
      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert drain(:login_page) == 1
    end

    test "a captcha on re-login moves the indexer to needs_login", %{tracker: tracker} do
      logged_in(tracker)
      assert {:ok, [result]} = search(tracker)
      assert result.title == "Fictional.Salt.Meadow.S02E04.1080p.WEB-DL-INVENTED"

      Trackers.expire_sessions(tracker)

      assert {:error, %Error{type: :login_required}} = search(tracker)
      assert status(tracker) == "needs_login"
      assert drain(:login) == 0
      assert drain(:captcha_image) == 1
    end
  end

  describe "grab" do
    @describetag :tmp_dir
    @describetag :capture_log

    setup %{tmp_dir: tmp_dir} do
      Downloads.register_clients()
      watch = Path.join(tmp_dir, "watch")
      File.mkdir_p!(watch)
      File.mkdir_p!(Path.join(tmp_dir, "completed"))

      download_client_config_fixture(%{
        type: "blackhole",
        connection_settings: %{
          "watch_folder" => watch,
          "completed_folder" => Path.join(tmp_dir, "completed")
        }
      })

      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      {:ok, watch: watch}
    end

    test "Gazelle: the session and passkey fetch the torrent, which is left untouched", %{
      bypass: bypass,
      watch: watch
    } do
      tracker =
        bypass
        |> Trackers.start_tracker(:gazelle)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      log =
        capture_log([level: :info], fn ->
          {:ok, [result]} = search(tracker)
          assert {:ok, %Download{} = download} = Downloads.initiate_download(result, [])
          send(self(), {:download, download})
        end)

      assert_received {:download, download}
      assert_received {:tracker, :download, %{method: "GET", cookie: cookie}}
      assert cookie =~ "session=sid-"

      assert_grabbed_untouched(watch, @secrets.passkey)
      refute_secrets(log)
      refute_secrets(inspect(Repo.get!(Download, download.id).error_message))
    end

    test "UNIT3D: the rsskey link fetches the torrent, kept out of the logs", %{
      bypass: bypass,
      watch: watch
    } do
      tracker =
        bypass |> Trackers.start_tracker(:unit3d) |> configure(%{"apikey" => @secrets.apikey})

      log =
        capture_log([level: :info], fn ->
          {:ok, [result]} = search(tracker)
          assert {:ok, %Download{}} = Downloads.initiate_download(result, [])
        end)

      assert_received {:tracker, :download, %{method: "GET"}}
      assert_grabbed_untouched(watch, @secrets.passkey)
      refute_secrets(log)
    end

    test "captcha tracker: the stored session fetches the torrent", %{
      bypass: bypass,
      watch: watch
    } do
      tracker =
        bypass
        |> Trackers.start_tracker(:captcha)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      logged_in(tracker)

      log =
        capture_log([level: :info], fn ->
          {:ok, [result]} = search(tracker)
          assert {:ok, %Download{}} = Downloads.initiate_download(result, [])
        end)

      assert_received {:tracker, :download, %{method: "GET", cookie: cookie}}
      assert cookie =~ "c_secure_uid="
      assert_grabbed_untouched(watch, @secrets.harrow_passkey)
      refute_secrets(log)
    end

    # A definition with a `download:` block fetches the release through the
    # engine's download request, which logs at :debug.
    test "the engine's download request keeps the passkey out of debug logs", %{bypass: bypass} do
      tracker =
        bypass
        |> Trackers.start_tracker(:gazelle)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      {:ok, [result]} = search(tracker)

      {:ok, parsed} =
        Mydia.Indexers.CardigannParser.parse_definition(tracker.definition.definition)

      params = %{query_params: %{}, headers: [], method: :get, decode_body: false}

      Logger.configure(level: :debug)

      log =
        capture_log([level: :debug], fn ->
          Mydia.Indexers.CardigannSearchEngine.execute_download_request(
            parsed,
            result.download_url,
            params,
            %{},
            %{}
          )
        end)

      assert log =~ "Cardigann download request"
      refute_secrets(log)
    end

    test "a failed grab records no passkey in the history row or logs", %{bypass: bypass} do
      tracker =
        bypass
        |> Trackers.start_tracker(:gazelle)
        |> configure(%{"username" => @secrets.username, "password" => @secrets.password})

      {:ok, [result]} = search(tracker)
      # The tracker has since rotated the passkey.
      result = %{
        result
        | download_url:
            String.replace(result.download_url, @secrets.passkey, "x" <> @secrets.passkey)
      }

      {:ok, download} =
        Downloads.History.create_download(%{
          indexer: result.indexer,
          title: result.title,
          download_url: result.download_url
        })

      log =
        capture_log([level: :info], fn -> Downloads.Grabber.run_grab(download, result, []) end)

      row = Repo.get!(Download, download.id)
      assert row.error_message =~ "403"
      refute_secrets(row.error_message)
      refute_secrets(log)
    end
  end

  # Logs in through the Indexers page's path: Login.begin, then complete with the answers.
  defp logged_in(%{definition: definition}) do
    definition = Repo.get!(CardigannDefinition, definition.id)
    {:ok, parsed} = Mydia.Indexers.CardigannParser.parse_definition(definition.definition)

    assert {:needs_input, challenge} = Mydia.Indexers.Cardigann.Login.begin(parsed, definition)
    assert Enum.sort(challenge.fields) == ["2facode", "captcha"]

    assert {:ok, session} =
             Mydia.Indexers.Cardigann.Login.complete(challenge, %{
               "captcha" => @secrets.captcha,
               "2facode" => @secrets.twofa
             })

    Mydia.Indexers.Cardigann.SessionManager.store(definition, session)
    drain(:login)
    drain(:login_page)
    drain(:captcha_image)
  end

  defp assert_grabbed_untouched(watch, passkey) do
    assert [file] = File.ls!(watch)
    # ensure_torrent_trackers/1 leaves a torrent with an announce URL alone.
    assert File.read!(Path.join(watch, file)) == Trackers.private_torrent(passkey)
  end

  defp refute_secrets(text) do
    for secret <- Trackers.secret_values() do
      refute text =~ secret, "#{inspect(secret)} leaked into: #{text}"
    end
  end
end
