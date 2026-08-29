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
end
