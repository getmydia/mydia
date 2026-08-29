defmodule Mydia.Indexers.CardigannAuthTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.CardigannAuth
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Repo

  defp login_definition(login, settings \\ []) do
    %Parsed{
      id: "login-url",
      name: "Login URL",
      description: "",
      language: "en-US",
      type: "private",
      encoding: "UTF-8",
      links: ["https://abn.lol/"],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
      login: login,
      download: nil,
      settings: settings,
      request_delay: nil,
      follow_redirect: true
    }
  end

  describe "authenticate/3 with form login" do
    setup do
      definition = %Parsed{
        id: "test-private",
        name: "Test Private Tracker",
        description: "Test",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["https://test-tracker.example"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          rows: %{selector: "tr"},
          fields: %{
            "title" => %{selector: "td.title"},
            "download" => %{selector: "a.download", attribute: "href"}
          }
        },
        login: %{
          method: "form",
          path: "/login.php",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          },
          test: %{
            selector: "a[href*=logout]"
          }
        }
      }

      {:ok, definition: definition}
    end

    test "successfully authenticates with valid credentials using Bypass", %{
      definition: definition
    } do
      bypass = Bypass.open()

      # Update definition to use bypass URL
      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}

      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        # Verify login params
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["username"] == "testuser"
        assert params["password"] == "testpass"

        # Return successful login response with cookies
        # Note: Req/Plug may merge multiple set-cookie headers into a list
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=abc123; Path=/")
        |> Plug.Conn.resp(
          200,
          "<html><body><a href='/logout'>Logout</a></body></html>"
        )
      end)

      user_config = %{username: "testuser", password: "testpass"}

      assert {:ok, session} = CardigannAuth.authenticate(definition, user_config)
      assert session.method == :form
      assert session.cookies != []
      assert Enum.any?(session.cookies, fn cookie -> String.starts_with?(cookie, "session=") end)
      assert %DateTime{} = session.expires_at
    end

    test "fails authentication when login returns error selector", %{definition: definition} do
      bypass = Bypass.open()
      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}

      # Add error selector to definition
      definition = put_in(definition.login[:error], [%{selector: "div.error"}])

      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        conn
        |> Plug.Conn.resp(
          200,
          "<html><body><div class='error'>Invalid credentials</div></body></html>"
        )
      end)

      user_config = %{username: "wrong", password: "wrong"}

      assert {:error, error} = CardigannAuth.authenticate(definition, user_config)
      assert error.message =~ "Login failed"
    end

    test "fails when test selector not found after login", %{definition: definition} do
      bypass = Bypass.open()
      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}

      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        # Return success but without the test selector
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=abc123")
        |> Plug.Conn.resp(200, "<html><body><p>Welcome</p></body></html>")
      end)

      user_config = %{username: "testuser", password: "testpass"}

      assert {:error, error} = CardigannAuth.authenticate(definition, user_config)
      assert error.message =~ "test selector not found"
    end

    test "stores session in database when definition ID provided", %{definition: definition} do
      bypass = Bypass.open()
      definition = %{definition | links: ["http://localhost:#{bypass.port}"]}

      Bypass.expect_once(bypass, "POST", "/login.php", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=abc123")
        |> Plug.Conn.resp(
          200,
          "<html><body><a href='/logout'>Logout</a></body></html>"
        )
      end)

      # Create a definition in DB
      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-private",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      user_config = %{username: "testuser", password: "testpass"}

      assert {:ok, _session} =
               CardigannAuth.authenticate(definition, user_config, cardigann_def.id)

      # Verify session was stored
      stored_session =
        Repo.get_by(CardigannSearchSession, cardigann_definition_id: cardigann_def.id)

      assert stored_session != nil
      assert stored_session.cookies != nil
      assert stored_session.expires_at != nil
    end

    test "an operator override of a login-path setting reaches the login request" do
      override = Bypass.open()

      Bypass.expect_once(override, "POST", "/api/login", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=granted; Path=/")
        |> Plug.Conn.resp(200, "<html>welcome</html>")
      end)

      parsed = %Parsed{
        id: "login-override",
        name: "Login Override",
        description: "",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:1/"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
        login: %{
          method: "form",
          path: "http://{{ .Config.apiurl }}/api/login",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          }
        },
        download: nil,
        settings: [%{name: "apiurl", type: "text", default: "localhost:2"}],
        request_delay: nil,
        follow_redirect: true
      }

      assert {:ok, _session} =
               CardigannAuth.authenticate(parsed, %{
                 username: "me",
                 password: "secret",
                 config: %{"apiurl" => "localhost:#{override.port}"}
               })
    end
  end

  describe "authenticate/3 with API key" do
    setup do
      definition = %Parsed{
        id: "test-api",
        name: "Test API Tracker",
        description: "Test",
        language: "en-US",
        type: "semi-private",
        encoding: "UTF-8",
        links: ["https://test-api.example"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/api/search"}],
          rows: %{selector: "$.results"},
          fields: %{
            "title" => %{selector: "title"},
            "download" => %{selector: "download_url"}
          }
        },
        login: %{
          method: "api"
        }
      }

      {:ok, definition: definition}
    end

    test "successfully authenticates with API key", %{definition: definition} do
      user_config = %{api_key: "secret-api-key-123"}

      assert {:ok, session} = CardigannAuth.authenticate(definition, user_config)
      assert session.method == :api_key
      assert session.api_key == "secret-api-key-123"
      assert session.cookies == []
      assert session.expires_at == nil
    end

    test "fails when API key not provided", %{definition: definition} do
      user_config = %{}

      assert {:error, error} = CardigannAuth.authenticate(definition, user_config)
      assert error.message =~ "API key required"
    end
  end

  describe "authenticate/3 with user-provided cookies" do
    test "successfully stores user-provided cookies" do
      definition = %Parsed{
        id: "test-cookie",
        name: "Test Cookie Tracker",
        description: "Test",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["https://test.example"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          rows: %{selector: "tr"},
          fields: %{
            "title" => %{selector: "td.title"},
            "download" => %{selector: "a", attribute: "href"}
          }
        },
        login: %{method: "cookie"}
      }

      user_config = %{cookies: ["session=xyz789", "remember=1"]}

      assert {:ok, session} = CardigannAuth.authenticate(definition, user_config)
      assert session.method == :cookie
      assert session.cookies == ["session=xyz789", "remember=1"]
      assert %DateTime{} = session.expires_at
    end

    test "handles single cookie string" do
      definition = %Parsed{
        id: "test-cookie",
        name: "Test",
        description: "Test",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["https://test.example"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          rows: %{selector: "tr"},
          fields: %{"title" => "td", "download" => "a"}
        },
        login: nil
      }

      user_config = %{cookies: "session=xyz789; uid=123"}

      assert {:ok, session} = CardigannAuth.authenticate(definition, user_config)
      assert session.cookies == ["session=xyz789; uid=123"]
    end
  end

  describe "validate_session/2" do
    test "returns true for non-expiring sessions" do
      session = %{cookies: ["session=abc"], expires_at: nil, method: :api_key}

      assert CardigannAuth.validate_session(session, nil) == true
    end

    test "returns true for valid unexpired sessions" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      session = %{cookies: ["session=abc"], expires_at: expires_at, method: :form}

      assert CardigannAuth.validate_session(session, nil) == true
    end

    test "returns false for expired sessions" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      session = %{cookies: ["session=abc"], expires_at: expires_at, method: :form}

      assert CardigannAuth.validate_session(session, nil) == false
    end
  end

  describe "get_stored_session/1 and store_session/3" do
    test "stores and retrieves session cookies" do
      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-storage",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      cookies = ["session=secret123", "uid=456"]
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, stored} =
               CardigannAuth.store_session(cardigann_def.id, cookies, expires_at)

      assert stored.cardigann_definition_id == cardigann_def.id

      # Verify cookies are stored directly as a list
      assert is_list(stored.cookies)
      assert stored.cookies == cookies

      # Retrieve and verify
      assert {:ok, retrieved} = CardigannAuth.get_stored_session(cardigann_def.id)
      assert retrieved.cookies == cookies
      # Allow for slight timing differences in DateTime comparison
      assert_in_delta DateTime.to_unix(retrieved.expires_at), DateTime.to_unix(expires_at), 1
    end

    test "returns :not_found when no session exists" do
      non_existent_id = Ecto.UUID.generate()
      assert {:error, :not_found} = CardigannAuth.get_stored_session(non_existent_id)
    end

    test "returns :expired for expired sessions" do
      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-expired",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      cookies = ["session=old"]
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert {:ok, _stored} =
               CardigannAuth.store_session(cardigann_def.id, cookies, expires_at)

      assert {:error, :expired} = CardigannAuth.get_stored_session(cardigann_def.id)
    end
  end

  describe "refresh_session/3" do
    test "refreshes expired session with new authentication using Bypass" do
      bypass = Bypass.open()

      definition = %Parsed{
        id: "test-refresh",
        name: "Test Refresh",
        description: "Test",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:#{bypass.port}"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          rows: %{selector: "tr"},
          fields: %{"title" => "td", "download" => "a"}
        },
        login: %{
          method: "form",
          path: "/login.php",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          },
          test: %{selector: "a.logout"}
        }
      }

      Bypass.expect(bypass, "POST", "/login.php", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=refreshed123")
        |> Plug.Conn.resp(200, "<html><a class='logout'>Logout</a></html>")
      end)

      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-refresh",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      user_config = %{username: "testuser", password: "testpass"}

      assert {:ok, refreshed} =
               CardigannAuth.refresh_session(definition, user_config, cardigann_def.id)

      assert refreshed.method == :form
      assert "session=refreshed123" in refreshed.cookies
    end
  end

  describe "public indexers (no authentication)" do
    test "returns empty session for public indexers" do
      definition = %Parsed{
        id: "test-public",
        name: "Test Public",
        description: "Test",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: ["https://public.example"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "/search"}],
          rows: %{selector: "tr"},
          fields: %{"title" => "td", "download" => "a"}
        },
        login: nil
      }

      user_config = %{}

      assert {:ok, session} = CardigannAuth.authenticate(definition, user_config)
      assert session.method == :none
      assert session.cookies == []
      assert session.expires_at == nil
    end
  end

  describe "build_login_url/2" do
    test "joins a relative login path onto the site link" do
      parsed = login_definition(%{method: "form", path: "/login.php"})

      assert {:ok, "https://abn.lol/login.php"} = CardigannAuth.build_login_url(parsed, %{})
    end

    test "an absolute login path is used as-is, not appended to the site link" do
      parsed = login_definition(%{method: "form", path: "https://auth.abn.lol/api/login"})

      assert {:ok, "https://auth.abn.lol/api/login"} = CardigannAuth.build_login_url(parsed, %{})
    end

    test "a templated login path is rendered before use" do
      parsed =
        login_definition(
          %{method: "form", path: "https://{{ .Config.apiurl }}/api/Release/Search"},
          [%{name: "apiurl", type: "text", default: "api.abn.lol"}]
        )

      assert {:ok, "https://api.abn.lol/api/Release/Search"} =
               CardigannAuth.build_login_url(parsed, %{})
    end

    test "an operator override of the setting is honoured" do
      parsed =
        login_definition(
          %{method: "form", path: "https://{{ .Config.apiurl }}/api"},
          [%{name: "apiurl", type: "text", default: "api.abn.lol"}]
        )

      assert {:ok, "https://api.mine.example/api"} =
               CardigannAuth.build_login_url(parsed, %{"apiurl" => "api.mine.example"})
    end

    test "a missing login path is an error" do
      assert {:error, _} = CardigannAuth.build_login_url(login_definition(%{method: "form"}), %{})
    end

    test "a definition with no login block names the login path as the problem" do
      parsed = login_definition(nil)

      assert {:error, %{message: message}} = CardigannAuth.build_login_url(parsed, %{})
      assert message =~ "Login path not configured"
    end

    test "a definition with no site link names the site link as the problem" do
      parsed = %{login_definition(%{method: "form", path: "/login.php"}) | links: []}

      assert {:error, %{message: message}} = CardigannAuth.build_login_url(parsed, %{})
      assert message =~ "No site link configured"
    end
  end

  describe "form login credential scope" do
    test "refuses to POST credentials over cleartext to a non-loopback host" do
      parsed =
        login_definition(%{
          method: "form",
          path: "/login.php",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          }
        })

      parsed = %{parsed | links: ["http://tracker.example"]}

      assert {:error, error} =
               CardigannAuth.authenticate(parsed, %{username: "me", password: "secret"})

      assert error.message =~ "unencrypted"
      assert error.message =~ "tracker.example"
    end

    test "allows a login on a host the definition names" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/login", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "session=granted; Path=/")
        |> Plug.Conn.resp(200, "<html>welcome</html>")
      end)

      parsed = %Parsed{
        id: "login-scope-ok",
        name: "Login Scope OK",
        description: "",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:#{bypass.port}"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
        login: %{
          method: "form",
          path: "/login",
          inputs: %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          }
        },
        download: nil,
        settings: [],
        request_delay: nil,
        follow_redirect: true
      }

      assert {:ok, %{cookies: cookies}} =
               CardigannAuth.authenticate(parsed, %{username: "me", password: "secret"})

      assert Enum.any?(cookies, &String.contains?(&1, "session=granted"))
    end
  end
end
