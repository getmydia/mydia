defmodule MydiaWeb.FlashComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias MydiaWeb.Layouts

  defp query(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(html, selector), do: html |> query(selector) |> Enum.count()

  defp render_group(flash) do
    assigns = %{flash: flash}

    rendered_to_string(~H"""
    <Layouts.flash_group flash={@flash} />
    """)
  end

  test "info and error stack inside one toast container above modals" do
    html = render_group(%{"info" => "Saved", "error" => "Connection failed"})

    assert count(html, "#flash-group.toast.toast-top.toast-end") == 1
    assert count(html, ~s(#flash-group[class*="z-[1000]"])) == 1
    assert count(html, "#flash-group > #flash-info") == 1
    assert count(html, "#flash-group > #flash-error") == 1
    assert count(html, "#flash-info.toast, #flash-error.toast") == 0
  end

  test "an empty container never swallows clicks on the page beneath it" do
    html = render_group(%{"info" => "Saved"})

    assert count(html, "#flash-group.pointer-events-none") == 1
    assert count(html, "#flash-info.pointer-events-auto") == 1
  end

  test "info dismisses after 5s and error after 10s" do
    html = render_group(%{"info" => "Saved", "error" => "Connection failed"})

    assert count(html, ~s(#flash-info[phx-hook="FlashAutoDismiss"][data-dismiss-after="5000"])) ==
             1

    assert count(html, ~s(#flash-error[phx-hook="FlashAutoDismiss"][data-dismiss-after="10000"])) ==
             1
  end

  test "reconnect toasts have no timer" do
    html = render_group(%{})

    for id <- ~w(client-error server-error) do
      assert count(html, "##{id}") == 1
      assert count(html, "##{id}[phx-hook]") == 0, "#{id} must not auto-dismiss"
      assert count(html, "##{id}[data-dismiss-after]") == 0
    end
  end

  test "dismiss_after can be overridden" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <MydiaWeb.FlashComponents.flash kind={:info} dismiss_after={nil}>
        Sticky
      </MydiaWeb.FlashComponents.flash>
      """)

    assert count(html, "#flash-info[phx-hook]") == 0
  end
end
