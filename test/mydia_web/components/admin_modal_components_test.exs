defmodule MydiaWeb.AdminModalComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MydiaWeb.AdminComponents
  alias MydiaWeb.AdminModalComponents

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  describe "admin_modal/1" do
    test "fills the screen on phones and lets field labels wrap" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal
          id="m"
          icon="hero-plus-circle"
          title="Add"
          on_close="close_m"
        >
          body
        </AdminModalComponents.admin_modal>
        """)

      for class <-
            ~w(max-sm:w-full max-sm:max-w-none max-sm:h-full max-sm:max-h-none max-sm:rounded-none) do
        assert count(html, ~s(#m .modal-box[class*="#{class}"])) == 1, "missing #{class}"
      end

      assert count(html, ~s(#m .modal-box[class*="[&_.label]:whitespace-normal"])) == 1
      assert count(html, "#m .modal-box.max-w-2xl") == 1
    end

    test "renders the standard shell at the default width" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal
          id="thing-modal"
          icon="hero-plus-circle"
          title="Add thing"
          subtitle="Configure a new thing"
          on_close="close_thing_modal"
        >
          <p id="body">fields</p>
          <:actions><button id="save">Save</button></:actions>
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, "#thing-modal.modal.modal-open[role=dialog]") == 1
      assert count(html, "#thing-modal .modal-box.max-w-2xl") == 1
      assert count(html, "#thing-modal .w-10.h-10.rounded-xl.bg-primary\\/20") == 1
      assert count(html, "#thing-modal-title") == 1
      assert html =~ "Configure a new thing"
      assert count(html, "#thing-modal #body") == 1
      assert count(html, ".modal-action.mt-6.pt-4.border-t.border-base-300 #save") == 1

      assert count(html, ".modal-backdrop.bg-black\\/50[phx-click=close_thing_modal]") == 1
    end

    test "size :lg widens the box" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal
          id="m"
          icon="hero-book-open"
          title="Browse"
          on_close="close_m"
          size={:lg}
        >
          x
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, ".modal-box.max-w-4xl") == 1
    end

    test "omits the action row when no actions slot is given" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal id="m" icon="hero-book-open" title="T" on_close="close_m">
          x
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, ".modal-action") == 0
    end

    test "tone :error tints the icon tile" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal
          id="m"
          icon="hero-trash"
          title="Empty the trash?"
          on_close="close_m_modal"
          tone={:error}
        >
          body
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, ".w-10.h-10.rounded-xl.bg-error\\/20") == 1
      assert count(html, ".bg-primary\\/20") == 0
    end

    test "on_close nil keeps the backdrop but makes it inert" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal id="m" icon="hero-key" title="Your key" on_close={nil}>
          body
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, ".modal-backdrop.bg-black\\/50") == 1
      assert count(html, ".modal-backdrop[phx-click]") == 0
    end

    test "header close button sends on_close" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal id="m" icon="hero-book-open" title="T" on_close="close_m">
          x
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, ~s(#m button#m-close[type=button][aria-label=Close][phx-click=close_m])) ==
               1
    end

    test "on_close nil renders no close button" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal id="m" icon="hero-key" title="T" on_close={nil}>
          x
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, "#m-close") == 0
    end

    test "body scrolls between a fixed header and action row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <AdminModalComponents.admin_modal id="m" icon="hero-book-open" title="T" on_close="close_m">
          <p id="inside">x</p>
          <:actions><button id="save">Save</button></:actions>
        </AdminModalComponents.admin_modal>
        """)

      assert count(html, "#m .modal-box.flex.flex-col.overflow-hidden") == 1
      assert count(html, "#m-body.flex-1.min-h-0.overflow-y-auto #inside") == 1
      # The action row sits outside the scroller.
      assert count(html, "#m-body .modal-action") == 0
      assert count(html, "#m .modal-box > .modal-action #save") == 1
    end
  end

  test "admin_modal_actions/1 is the bordered action row" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <AdminModalComponents.admin_modal_actions>
        <button id="b">b</button>
      </AdminModalComponents.admin_modal_actions>
      """)

    assert count(
             html,
             ".modal-action.mt-6.pt-4.border-t.border-base-300.sticky.bottom-0.bg-base-100 #b"
           ) == 1
  end

  test "admin_header/1 renders the page header ids without the hub tab strip" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <AdminComponents.admin_header title="Import Lists" description="Lists to follow" count={2}>
        <:actions><button id="go">Go</button></:actions>
      </AdminComponents.admin_header>
      """)

    assert count(html, "#admin-page-header #admin-page-title") == 1
    assert count(html, "#admin-page-count") == 1
    assert count(html, "#admin-page-description") == 1
    assert count(html, "#admin-page-actions #go") == 1
    assert count(html, "#admin-page-hub") == 0
    assert count(html, "#admin-page-tabs") == 0
  end

  test "admin_page/1 wraps the hub tab strip instead of scrolling it" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <AdminComponents.admin_page page={:trash}>body</AdminComponents.admin_page>
      """)

    assert count(html, "nav#admin-page-tabs.tabs.flex-wrap") == 1
    assert count(html, "nav#admin-page-tabs.overflow-x-auto") == 0
    assert count(html, "nav#admin-page-tabs.flex-nowrap") == 0
  end

  test "admin_page/1 supplies the body wrapper, with no side padding on phones" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <AdminComponents.admin_page page={:trash}>
        <p id="inside">x</p>
      </AdminComponents.admin_page>
      """)

    assert count(html, "div#admin-page-body.bg-base-100.py-4.space-y-4 #inside") == 1
    assert count(html, ~s(div#admin-page-body[class*="sm:p-6"])) == 1
    assert count(html, "div#admin-page-body.p-4") == 0
    assert count(html, "div#admin-page-body.px-4") == 0
  end
end
