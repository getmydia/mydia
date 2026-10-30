defmodule MydiaWeb.AdminIndexersLive.TrackerTermsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Indexers.TrackerSightings.Sighting
  alias Mydia.Repo
  alias Mydia.Settings.TrackerRuleConfigs
  alias Mydia.Indexers.Structs.TrackerTerms
  alias MydiaWeb.AdminIndexersLive.TrackerTermsComponents

  setup %{conn: conn} do
    start_supervised!(Mydia.Indexers.Health)
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp seen(tracker, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Sighting,
        Map.merge(
          %{
            tracker: tracker,
            tracker_key: String.downcase(tracker),
            last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )
    )
  end

  defp dom(key), do: TrackerTermsComponents.dom_key(key)

  test "lists seen trackers with their effective terms", %{conn: conn} do
    seen("Velvet Lantern", %{minimum_ratio: 1.0, private: true})

    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#tracker-terms-section")
    assert has_element?(view, "#tracker-#{dom("velvet lantern")}")
    assert has_element?(view, "#tracker-terms-#{dom("velvet lantern")}", "Ratio 1.0")
  end

  test "flags an override that matched nothing", %{conn: conn} do
    {:ok, rule} = TrackerRuleConfigs.create(%{tracker: "Ghost Reel", seed_ratio: 1.0})
    old = DateTime.add(DateTime.utc_now(), -60 * 86_400) |> DateTime.truncate(:second)
    rule |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#tracker-stale-#{dom("ghost reel")}")
  end

  test "editing a seen tracker creates an override", %{conn: conn} do
    seen("Velvet Lantern", %{minimum_ratio: 1.0})
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    view |> element("#edit-tracker-rule-#{dom("velvet lantern")}") |> render_click()
    assert has_element?(view, "#tracker-rule-modal")

    view
    |> form("#tracker-rule-form",
      tracker_rule_config: %{tracker: "Velvet Lantern", seed_ratio: "2.5", seed_time: "4320"}
    )
    |> render_submit()

    refute has_element?(view, "#tracker-rule-modal")
    assert has_element?(view, "#tracker-terms-#{dom("velvet lantern")}", "Ratio 2.5")
    assert has_element?(view, "#tracker-terms-#{dom("velvet lantern")}", "Seed 3d")
    assert [%{seed_ratio: 2.5, seed_time: 4320}] = TrackerRuleConfigs.list()
  end

  test "an override can cap daily grabs and queries", %{conn: conn} do
    seen("Velvet Lantern")
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    view |> element("#edit-tracker-rule-#{dom("velvet lantern")}") |> render_click()

    view
    |> form("#tracker-rule-form",
      tracker_rule_config: %{tracker: "Velvet Lantern", grab_limit: "5", query_limit: "50"}
    )
    |> render_submit()

    assert [%{grab_limit: 5, query_limit: 50}] = TrackerRuleConfigs.list()

    assert has_element?(
             view,
             "#tracker-limits-#{dom("velvet lantern")}",
             "5 grabs/day · 50 searches/day"
           )
  end

  test "an invalid override keeps the modal open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    view |> element("#new-tracker-rule") |> render_click()

    view
    |> form("#tracker-rule-form",
      tracker_rule_config: %{tracker: "Velvet Lantern", seed_ratio: "-1"}
    )
    |> render_submit()

    assert has_element?(view, "#tracker-rule-modal")
    assert TrackerRuleConfigs.list() == []
  end

  test "an override from the environment cannot be edited here", %{conn: conn} do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | tracker_rules: [%Mydia.Config.Schema.TrackerRule{tracker: "Copper Reel", seed_ratio: 1.0}]
    })

    seen("Copper Reel")
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")

    assert has_element?(view, "#edit-tracker-rule-#{dom("copper reel")}[disabled]")
  end

  test "a tracker seen after mount appears when the page reloads its indexers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/indexers")
    refute has_element?(view, "#tracker-#{dom("late reel")}")

    seen("Late Reel")
    send(view.pid, :reload_library_indexers)

    assert has_element?(view, "#tracker-#{dom("late reel")}")
  end

  test "seed times format as seconds, minutes, hours or days" do
    summary = &TrackerTermsComponents.terms_summary(%TrackerTerms{minimum_seed_time: &1})

    assert summary.(30) == "Seed 30s"
    assert summary.(90) == "Seed 1m"
    assert summary.(7200) == "Seed 2h"
    assert summary.(259_200) == "Seed 3d"
  end
end
