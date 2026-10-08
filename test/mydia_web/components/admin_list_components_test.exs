defmodule MydiaWeb.AdminListComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MydiaWeb.AdminListComponents

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp count(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.count()

  describe "admin_section/1" do
    test "renders an h2 with a dimmed icon and an optional count" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_section id="s" title="Needs Attention" icon="hero-bell" count={3}>
          <p id="body">inside</p>
        </AdminListComponents.admin_section>
        """)

      assert count(html, "h2#s-title.text-lg.font-semibold") == 1
      assert count(html, "h2 .w-5.h-5.opacity-60") == 1
      assert count(html, "h2 .badge.badge-ghost") == 1
      assert count(html, "#body") == 1
    end

    test "omits the count badge when count is nil" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_section title="Jobs" icon="hero-clock">
          x
        </AdminListComponents.admin_section>
        """)

      assert count(html, ".badge") == 0
    end
  end

  describe "admin_list/1" do
    test "renders an info alert and no container when empty" do
      assigns = %{items: []}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_list id="things" items={@items}>
          <:row :let={item}>{item}</:row>
          <:empty>Nothing yet.</:empty>
        </AdminListComponents.admin_list>
        """)

      assert count(html, "#things-empty.alert.alert-info") == 1
      assert html =~ "Nothing yet."
      assert count(html, "#things") == 0
    end

    test "renders the standard container and one row per item" do
      assigns = %{items: ["a", "b"]}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_list id="things" items={@items}>
          <:row :let={item}>
            <div class="row">{item}</div>
          </:row>
          <:empty>Nothing yet.</:empty>
        </AdminListComponents.admin_list>
        """)

      assert count(html, "#things.bg-base-200.rounded-box.divide-y.divide-base-300") == 1
      assert count(html, "#things .row") == 2
      assert count(html, "#things-empty") == 0
    end
  end

  describe "admin_row/1" do
    test "renders title, truncating descriptor, badges and actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_row id="row-1">
          <:title>Name</:title>
          <:descriptor>desc</:descriptor>
          <:badges><span class="badge">b</span></:badges>
          <:actions><span id="act">a</span></:actions>
        </AdminListComponents.admin_row>
        """)

      assert count(html, "#row-1.p-3") == 1
      assert count(html, "#row-1 .flex-1.min-w-0") == 1
      assert count(html, "#row-1 .text-xs.opacity-60.truncate") == 1
      assert count(html, "#row-1 .badge") == 1
      assert count(html, "#row-1 #act") == 1
    end

    test "omits the descriptor line when the slot is absent" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_row id="row-1">
          <:title>Name</:title>
        </AdminListComponents.admin_row>
        """)

      assert count(html, ".truncate") == 0
    end
  end

  describe "row_action/1" do
    # Global attrs (phx-*, data-*) are only gathered into :rest when the
    # component is called from HEEx, so this test renders through ~H rather
    # than render_component/2.
    test "is an icon-only ghost join button with a title and aria-label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.row_action
          icon="hero-pencil"
          title="Edit"
          id="edit-1"
          phx-click="edit_thing"
          phx-value-id="1"
        />
        """)

      assert count(
               html,
               "button#edit-1.btn.btn-sm.btn-ghost.join-item[title=Edit][aria-label=Edit]"
             ) ==
               1

      assert count(html, "button[phx-click=edit_thing][phx-value-id='1']") == 1
      refute html =~ "text-error"
      refute html =~ "tooltip"
    end

    test "destructive adds text-error" do
      html =
        render_component(&AdminListComponents.row_action/1,
          icon: "hero-trash",
          title: "Delete",
          destructive: true
        )

      assert count(html, "button.text-error") == 1
    end

    test "disabled with a reason wraps the button in a tooltip and dims the icon" do
      html =
        render_component(&AdminListComponents.row_action/1,
          icon: "hero-trash",
          title: "Delete",
          disabled: true,
          disabled_reason: "Configured via environment variables"
        )

      assert count(
               html,
               "div.tooltip[data-tip='Configured via environment variables'] > button[disabled]"
             ) ==
               1

      assert count(html, "button .opacity-30") == 1
    end

    test "loading replaces the icon with a spinner and disables the button" do
      html =
        render_component(&AdminListComponents.row_action/1,
          icon: "hero-signal",
          title: "Test",
          loading: true
        )

      assert count(html, "button[disabled] .loading.loading-spinner") == 1
      assert count(html, "button .hero-signal") == 0
    end
  end

  test "row_actions/1 is the right-aligned join" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <AdminListComponents.row_actions><span id="x">x</span></AdminListComponents.row_actions>
      """)

    assert count(html, "div.join.ml-auto #x") == 1
  end

  test "env_lock_badge/1 is the primary xs lock badge" do
    html = render_component(&AdminListComponents.env_lock_badge/1, %{})
    assert count(html, "span.badge.badge-primary.badge-xs .hero-lock-closed") == 1
    assert html =~ "ENV"
  end

  describe "admin_table/1" do
    test "renders the empty alert when there are no rows" do
      assigns = %{rows: []}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_table id="t" rows={@rows}>
          <:col :let={r} label="Name">{r}</:col>
          <:empty>No rows.</:empty>
        </AdminListComponents.admin_table>
        """)

      assert count(html, "#t-empty.alert.alert-info") == 1
      assert count(html, "table") == 0
    end

    test "renders headers, cells, row ids and an actions column" do
      assigns = %{rows: [%{id: "1", name: "One"}, %{id: "2", name: "Two"}]}

      html =
        rendered_to_string(~H"""
        <AdminListComponents.admin_table id="t" rows={@rows} row_id={&"t-row-#{&1.id}"}>
          <:col :let={r} label="Name">{r.name}</:col>
          <:action :let={r}>
            <AdminListComponents.row_action icon="hero-trash" title="Delete" id={"del-#{r.id}"} />
          </:action>
          <:empty>No rows.</:empty>
        </AdminListComponents.admin_table>
        """)

      assert count(html, "#t table.table.table-zebra") == 1
      assert count(html, "#t thead th") == 2
      assert count(html, "#t-row-1") == 1
      assert count(html, "#t-row-2 .join #del-2") == 1
    end
  end
end
