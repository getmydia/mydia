defmodule Mydia.Indexers.Cardigann.CredentialScopeTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannParser

  @corpus Path.wildcard("test/fixtures/cardigann/**/*.yml")

  defp absolute_urls(parsed) do
    search =
      case parsed.search do
        %{} = s -> Map.get(s, :paths) || []
        _ -> []
      end

    search_paths = Enum.map(search, fn p -> Map.get(p, :path) end)
    login = if is_map(parsed.login), do: [Map.get(parsed.login, :path)], else: []

    (login ++ search_paths)
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&String.match?(&1, ~r{^https?://}i))
    |> Enum.flat_map(fn template ->
      context = %{
        keywords: "",
        config: %{},
        query: %{series: ""},
        categories: [],
        settings: parsed.settings
      }

      case Mydia.Indexers.CardigannTemplate.render(template, context, url_encode: false) do
        {:ok, rendered} -> [rendered]
        _ -> []
      end
    end)
  end

  defp definition(overrides \\ []) do
    base = %Parsed{
      id: "scope-test",
      name: "Scope Test",
      description: "",
      language: "en-US",
      type: "private",
      encoding: "UTF-8",
      links: ["https://tracker.example/", "https://mirror.example"],
      legacylinks: ["https://old-tracker.example/"],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
      login: nil,
      download: nil,
      settings: [],
      request_delay: nil,
      follow_redirect: true
    }

    struct!(base, overrides)
  end

  describe "trusted_hosts/2" do
    test "includes every host in links" do
      hosts = CredentialScope.trusted_hosts(definition(), %{})

      assert MapSet.member?(hosts, "tracker.example")
      assert MapSet.member?(hosts, "mirror.example")
    end

    test "excludes legacylinks" do
      hosts = CredentialScope.trusted_hosts(definition(), %{})

      refute MapSet.member?(hosts, "old-tracker.example")
    end

    test "includes the host of an absolute search path" do
      parsed =
        definition(
          search: %{
            paths: [%{path: "https://api.tracker.example/v1/search"}],
            inputs: %{},
            rows: %{},
            fields: %{}
          }
        )

      hosts = CredentialScope.trusted_hosts(parsed, %{})

      assert MapSet.member?(hosts, "api.tracker.example")
    end

    test "renders a templated absolute path from a setting default" do
      parsed =
        definition(
          settings: [%{name: "apiurl", type: "text", default: "api.v3x.club"}],
          search: %{
            paths: [%{path: "https://{{ .Config.apiurl }}/indexer/search"}],
            inputs: %{},
            rows: %{},
            fields: %{}
          }
        )

      hosts = CredentialScope.trusted_hosts(parsed, %{})

      assert MapSet.member?(hosts, "api.v3x.club")
    end

    test "an operator override of the setting wins over the default" do
      parsed =
        definition(
          settings: [%{name: "apiurl", type: "text", default: "api.v3x.club"}],
          search: %{
            paths: [%{path: "https://{{ .Config.apiurl }}/indexer/search"}],
            inputs: %{},
            rows: %{},
            fields: %{}
          }
        )

      hosts = CredentialScope.trusted_hosts(parsed, %{"apiurl" => "api.mine.example"})

      assert MapSet.member?(hosts, "api.mine.example")
      refute MapSet.member?(hosts, "api.v3x.club")
    end

    test "includes the host of an absolute login path" do
      parsed = definition(login: %{method: "form", path: "https://auth.tracker.example/login"})

      hosts = CredentialScope.trusted_hosts(parsed, %{})

      assert MapSet.member?(hosts, "auth.tracker.example")
    end

    test "a relative path contributes no host" do
      hosts = CredentialScope.trusted_hosts(definition(), %{})

      assert MapSet.size(hosts) == 2
    end
  end

  describe "allows?/2" do
    setup do
      %{hosts: CredentialScope.trusted_hosts(definition(), %{})}
    end

    test "allows an exact host match", %{hosts: hosts} do
      assert CredentialScope.allows?(hosts, "https://tracker.example/search?q=x")
    end

    test "match is case insensitive", %{hosts: hosts} do
      assert CredentialScope.allows?(hosts, "https://TRACKER.Example/search")
    end

    test "refuses a host outside the set", %{hosts: hosts} do
      refute CredentialScope.allows?(hosts, "https://evil.example/search")
    end

    test "refuses a legacy host", %{hosts: hosts} do
      refute CredentialScope.allows?(hosts, "https://old-tracker.example/search")
    end

    # limetorrents.proxyninja.net and extratorrent.ninjaproxy1.com are real
    # shipped links entries on shared proxy services fronting many unrelated
    # trackers. A subdomain-suffix rule would leak one tracker's session to a
    # neighbour behind the same proxy.
    test "refuses a subdomain of a trusted host", %{hosts: hosts} do
      refute CredentialScope.allows?(hosts, "https://sub.tracker.example/search")
    end

    test "refuses a parent domain of a trusted host" do
      hosts = CredentialScope.trusted_hosts(definition(links: ["https://a.proxy.example"]), %{})

      refute CredentialScope.allows?(hosts, "https://proxy.example/search")
    end

    test "refuses a url with no host", %{hosts: hosts} do
      refute CredentialScope.allows?(hosts, "/search")
      refute CredentialScope.allows?(hosts, "magnet:?xt=urn:btih:abc")
    end
  end

  describe "credentialed?/1" do
    test "true for a non-empty cookie list" do
      assert CredentialScope.credentialed?(%{cookies: ["session=abc"]})
    end

    test "true for a string-keyed username, as definition.config supplies" do
      assert CredentialScope.credentialed?(%{"username" => "me", "password" => "secret"})
    end

    test "true for an api key under either spelling" do
      assert CredentialScope.credentialed?(%{api_key: "k"})
      assert CredentialScope.credentialed?(%{"apikey" => "k"})
    end

    test "false for blanks, which is how the admin form submits untouched fields" do
      refute CredentialScope.credentialed?(%{"username" => "", cookies: [], password: nil})
    end

    test "false for a config holding only non-credential settings" do
      refute CredentialScope.credentialed?(%{"apiurl" => "api.example", "sort" => "seeders"})
    end
  end

  # A static guard that the policy never strips a legitimate shipped definition.
  # Every absolute search or login path in the fixture corpus must resolve, with
  # its own setting defaults, to a host that definition already trusts. If a
  # future definition breaks this, the policy needs revisiting rather than the
  # definition being silently searched anonymously.
  describe "shipped definition corpus" do
    test "every absolute path in the corpus lands inside its own trusted set" do
      assert @corpus != [], "no cardigann fixtures found; check the wildcard"

      # `{:ok, parsed} <- [...]` filters a parse failure out of the comprehension
      # rather than raising, so one unparseable fixture cannot mask the guard.
      offenders =
        for file <- @corpus,
            {:ok, parsed} <- [CardigannParser.parse_definition(File.read!(file))],
            hosts = CredentialScope.trusted_hosts(parsed, %{}),
            url <- absolute_urls(parsed),
            not CredentialScope.allows?(hosts, url) do
          {Path.basename(file), url}
        end

      assert offenders == [],
             "these shipped definitions render an absolute path outside their own " <>
               "trusted host set: #{inspect(offenders)}"
    end
  end
end
