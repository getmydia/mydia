defmodule Mydia.CardigannLoginFixtures do
  @moduledoc false

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Repo

  @doc "A parsed definition for an invented tracker at `base`, with `login` merged over a post login."
  def parsed(base, login, settings \\ []) do
    %Parsed{
      id: "invented-tracker",
      name: "Invented Tracker",
      description: "",
      language: "en-US",
      type: "private",
      encoding: "UTF-8",
      links: [base],
      legacylinks: [],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/browse.php"}], inputs: %{}, rows: %{}, fields: %{}},
      login:
        Map.merge(
          %{
            method: "post",
            path: "/login.php",
            submitpath: nil,
            form: "form",
            selectors: false,
            inputs: %{},
            selectorinputs: %{},
            getselectorinputs: %{},
            error: [],
            test: nil,
            cookies: [],
            captcha: nil,
            headers: %{}
          },
          login
        ),
      download: nil,
      settings: settings,
      follow_redirect: true
    }
  end

  @doc "Inserts a CardigannDefinition row whose user config is `config`."
  def definition(config, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %CardigannDefinition{
          indexer_id: "invented-tracker-#{System.unique_integer([:positive])}",
          name: "Invented Tracker",
          type: "private",
          links: %{"urls" => []},
          capabilities: %{},
          definition: "id: invented-tracker",
          schema_version: "v11",
          enabled: true,
          in_library: true,
          config: config
        },
        attrs
      )
    )
  end
end
