defmodule MydiaWeb.CollectionLive.SmartRulesDialogTest do
  # async: false — a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Collections.SmartRulesFields

  @fields Map.keys(SmartRulesFields.field_definitions())

  setup %{conn: conn} do
    user = user_fixture()

    media_item_fixture(%{
      title: "Seeded Movie",
      metadata: %{
        genres: ["Action", "Drama"],
        original_language: "ja",
        status: "Released"
      }
    })

    %{conn: log_in_user(conn, user), user: user}
  end

  defp condition_params(field) do
    %{
      "collection" => %{"type" => "smart", "name" => "Nightly", "description" => ""},
      "match_type" => "all",
      "conditions" => %{"0" => %{"field" => field, "operator" => "eq", "value" => ""}},
      "sort_field" => "",
      "sort_direction" => "desc",
      "limit" => ""
    }
  end

  describe "create dialog" do
    for field <- @fields do
      test "selecting #{field} keeps the dialog alive", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/collections")

        view |> element("button[phx-click=open_new_modal]", "New Collection") |> render_click()

        html =
          view
          |> element("#new-collection-form")
          |> render_change(condition_params(unquote(field)))

        assert html =~ "Smart Rules"
        assert has_element?(view, ~s(select[name="conditions[0][operator]"]))
        assert render(view) =~ "Smart Rules"
      end
    end

    test "selecting Genre offers the genres present in the library", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      view |> element("button[phx-click=open_new_modal]", "New Collection") |> render_click()

      html =
        view
        |> element("#new-collection-form")
        |> render_change(condition_params("metadata.genres"))

      assert html =~ "Action"
      assert html =~ "Drama"
    end

    test "selecting Language offers the languages present in the library", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collections")

      view |> element("button[phx-click=open_new_modal]", "New Collection") |> render_click()

      html =
        view
        |> element("#new-collection-form")
        |> render_change(condition_params("metadata.original_language"))

      assert html =~ "Japanese"
    end
  end

  describe "edit dialog" do
    setup %{user: user} do
      {:ok, collection} =
        Collections.create_collection(user, %{
          name: "Existing Smart",
          type: "smart",
          visibility: "private",
          smart_rules:
            Jason.encode!(%{
              "match_type" => "all",
              "conditions" => [%{"field" => "year", "operator" => "gte", "value" => 2000}]
            })
        })

      %{collection: collection}
    end

    for field <- @fields do
      test "selecting #{field} keeps the editor alive", %{conn: conn, collection: collection} do
        {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

        view |> element("button.btn-ghost[phx-click=open_edit_modal]") |> render_click()

        html =
          view
          |> element("#edit-collection-form")
          |> render_change(condition_params(unquote(field)))

        assert html =~ "Smart Rules"
        assert has_element?(view, ~s(select[name="conditions[0][operator]"]))
      end
    end

    test "opening the editor via ?edit=true still offers the seeded options", %{
      conn: conn,
      collection: collection
    } do
      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")

      html =
        view
        |> element("#edit-collection-form")
        |> render_change(condition_params("metadata.genres"))

      assert html =~ "Action"
      assert html =~ "Drama"
    end
  end

  defp smart_collection!(user, name, condition) do
    {:ok, collection} =
      Collections.create_collection(user, %{
        name: name,
        type: "smart",
        visibility: "private",
        smart_rules: Jason.encode!(%{"match_type" => "all", "conditions" => [condition]})
      })

    collection
  end

  # The values the first condition's value input reports as selected. A single
  # select yields at most one; a multi-select yields one per stored value.
  defp selected_values(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(~s(select[name^="conditions[0][value]"] option[selected]))
    |> Floki.attribute("value")
  end

  describe "edit dialog preselects the stored condition value" do
    test "a genre some library item actually has", %{conn: conn, user: user} do
      collection =
        smart_collection!(user, "Dramas", %{
          "field" => "metadata.genres",
          "operator" => "contains",
          "value" => "Drama"
        })

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")

      assert selected_values(render(view)) == ["Drama"]
    end

    test "a genre no library item currently has", %{conn: conn, user: user} do
      collection =
        smart_collection!(user, "Documentaries", %{
          "field" => "metadata.genres",
          "operator" => "contains",
          "value" => "Documentary"
        })

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")

      assert selected_values(render(view)) == ["Documentary"]
    end

    test "every value of a multi-value category rule", %{conn: conn, user: user} do
      collection =
        smart_collection!(user, "Anime", %{
          "field" => "category",
          "operator" => "in",
          "value" => ["anime_movie", "anime_series"]
        })

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")

      assert selected_values(render(view)) == ["anime_movie", "anime_series"]
    end
  end

  describe "saving the edit dialog back preserves the rule" do
    # The edit form only renders the visibility select for admins, and
    # Collection.changeset/2 requires visibility, so only an admin submit
    # actually reaches the database.
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin), user: admin}
    end

    defp saved_conditions(user, collection) do
      user
      |> Collections.get_collection(collection.id)
      |> Map.fetch!(:smart_rules)
      |> Jason.decode!()
      |> Map.fetch!("conditions")
    end

    # Renaming proves the submit actually landed, so a preserved rule cannot be
    # confused with a rejected save that simply left the old one in place.
    defp submit_rename(view) do
      view
      |> form("#edit-collection-form", collection: %{name: "Renamed"})
      |> render_submit()
    end

    test "a genre no library item currently has", %{conn: conn, user: user} do
      condition = %{
        "field" => "metadata.genres",
        "operator" => "contains",
        "value" => "Documentary"
      }

      collection = smart_collection!(user, "Documentaries", condition)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")
      submit_rename(view)

      assert Collections.get_collection(user, collection.id).name == "Renamed"
      assert saved_conditions(user, collection) == [condition]
    end

    test "a multi-value category rule", %{conn: conn, user: user} do
      condition = %{
        "field" => "category",
        "operator" => "in",
        "value" => ["anime_movie", "anime_series"]
      }

      collection = smart_collection!(user, "Anime", condition)

      {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}?edit=true")
      submit_rename(view)

      assert Collections.get_collection(user, collection.id).name == "Renamed"
      assert saved_conditions(user, collection) == [condition]
    end
  end
end
