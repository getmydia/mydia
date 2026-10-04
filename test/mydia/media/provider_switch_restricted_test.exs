defmodule Mydia.Media.ProviderSwitchRestrictedTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0, warm_remote_signals: 3]

  alias Mydia.Accounts.Scope
  alias Mydia.Media.ProviderSwitch
  alias Mydia.Media.RemoteSignals

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    [ok, blocked] = for _ <- 1..2, do: unique_provider_id()

    warm_remote_signals(
      {:tmdb, ok},
      :tv_show,
      %RemoteSignals{content_rating: "TV-PG", age: 8, category: "tv_show"}
    )

    warm_remote_signals(
      {:tmdb, blocked},
      :tv_show,
      %RemoteSignals{content_rating: "TV-MA", age: 17, category: "tv_show"}
    )

    Bypass.stub(bypass, "GET", "/tmdb/tv/search", fn conn ->
      body = %{
        "results" => [
          %{"id" => ok, "name" => "Lantern Orchard", "first_air_date" => "1990-01-01"},
          %{"id" => blocked, "name" => "Lantern Tides", "first_air_date" => "1991-01-01"}
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    item = media_item_fixture(%{type: "tv_show", title: "Unrelated Harbor", year: 2002})
    %{config: config, item: item, ok: ok, blocked: blocked}
  end

  test "the re-identify picker lists everything to an unrestricted scope", c do
    assert {:needs_picker, candidates} =
             ProviderSwitch.find_reidentify_candidate(
               c.item,
               :tmdb,
               c.config,
               Scope.unrestricted()
             )

    assert candidates |> Enum.map(& &1.provider_id) |> Enum.sort() ==
             Enum.sort([to_string(c.ok), to_string(c.blocked)])
  end

  test "the re-identify picker drops titles a restricted scope may not see", c do
    scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))

    assert {:needs_picker, candidates} =
             ProviderSwitch.find_reidentify_candidate(c.item, :tmdb, c.config, scope)

    assert Enum.map(candidates, & &1.provider_id) == [to_string(c.ok)]
  end
end
