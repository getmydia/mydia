defmodule MydiaWeb.AdminPageConventionsTest do
  @moduledoc """
  Admin pages are built from `MydiaWeb.AdminListComponents` and
  `MydiaWeb.AdminModalComponents`, not copied class strings. This scan fails on
  the drift patterns an audit of every admin page found: hand-rolled modals,
  bare event names, fat templates, raw greys and `<.button>`.

  It cannot prove a page conforms, only catch those patterns. The standard
  itself is in `lib/mydia_web/components/README.md`.

  `@enforced` lists the page directories already migrated. Add a page when it
  moves onto the components.
  """

  use ExUnit.Case, async: true

  @live_root Path.expand("../../lib/mydia_web/live", __DIR__)
  @max_template_lines 60

  @enforced []

  @bare_events ~w(new edit save cancel close close_modal delete remove test validate filter)

  test "enforced pages follow the admin page conventions" do
    offenders =
      for dir <- @enforced,
          path <- Path.wildcard(Path.join([@live_root, dir, "**", "*.{ex,heex}"])),
          violation <- violations(File.read!(path), path) do
        "  #{Path.relative_to(path, @live_root)}: #{violation}"
      end

    assert offenders == [],
           "Admin pages drifted from the conventions in lib/mydia_web/components/README.md:\n" <>
             Enum.join(offenders, "\n")
  end

  test "every enforced directory exists" do
    missing = Enum.reject(@enforced, &File.dir?(Path.join(@live_root, &1)))
    assert missing == []
  end

  describe "the scanner" do
    test "flags a hand-rolled modal" do
      assert ["hand-rolled modal" <> _] = violations(~S(<div class="modal modal-open">), "x.ex")
      assert ["hand-rolled modal" <> _] = violations(~S(<div class="modal-box max-w-lg">), "x.ex")
    end

    test "flags bare event names on click, submit and change" do
      for event <- ~w(new save close_modal remove filter),
          attr <- ~w(phx-click phx-submit phx-change) do
        assert [msg] = violations(~s(<button #{attr}="#{event}">), "x.ex")
        assert msg =~ "bare event"
      end
    end

    test "allows namespaced event names" do
      assert violations(~S(<button phx-click="new_storage_backend">), "x.ex") == []
      assert violations(~S(<button phx-click="close_storage_backend_modal">), "x.ex") == []
    end

    test "flags a long index.html.heex but not a long components.ex" do
      long = String.duplicate("<div></div>\n", @max_template_lines + 1)
      assert ["template is" <> _] = violations(long, "admin_x_live/index.html.heex")
      assert violations(long, "admin_x_live/components.ex") == []
    end

    test "flags text-gray and <.button" do
      assert ["raw grey" <> _] = violations(~S(<p class="text-gray-500">), "x.ex")
      assert ["<.button>" <> _] = violations(~S(<.button class="btn">Go</.button>), "x.ex")
    end
  end

  defp violations(content, path) do
    [
      Regex.match?(~r/class="modal(-box)?[\s"]/, content) &&
        "hand-rolled modal; use <.admin_modal>",
      bare_event(content),
      template_too_long(content, path),
      content =~ "text-gray-" && "raw grey; use text-base-content/<n>",
      content =~ "<.button" && "<.button>; use a raw <button> or <.row_action>"
    ]
    |> Enum.filter(& &1)
  end

  defp bare_event(content) do
    names = Enum.join(@bare_events, "|")

    case Regex.run(~r/phx-(?:click|submit|change)="(#{names})"/, content) do
      [_, name] -> "bare event \"#{name}\"; name it <verb>_<thing>"
      nil -> nil
    end
  end

  defp template_too_long(content, path) do
    lines = content |> String.split("\n") |> length()

    (String.ends_with?(path, ".html.heex") and lines > @max_template_lines) &&
      "template is #{lines} lines (max #{@max_template_lines}); move markup to components.ex"
  end
end
