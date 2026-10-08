defmodule MydiaWeb.AdminPageConventionsTest do
  @moduledoc """
  Admin pages are built from `MydiaWeb.AdminListComponents` and
  `MydiaWeb.AdminModalComponents`, not copied class strings. This scan fails on
  the drift patterns an audit of every admin page found: hand-rolled modals,
  bare event names, fat templates, raw greys and `<.button>`.

  It cannot prove a page conforms, only catch those patterns. The standard
  itself is in `lib/mydia_web/components/README.md`.

  The scope is every `live` route under `/admin` in `MydiaWeb.Router`, so a new
  admin page is scanned from its first commit. `@pending` lists pages not yet
  migrated.
  """

  use ExUnit.Case, async: true

  @live_root Path.expand("../../lib/mydia_web/live", __DIR__)
  @max_template_lines 60

  # Pages not yet migrated, by directory basename (or file rootname for a
  # single-file LiveView). Each page task deletes its key.
  @pending ~w(
    admin_settings_live
    admin_system_live
    admin_dashboard_live
    admin_download_clients_live
    admin_library_paths_live
  )

  # Single files outside a page directory that hold migrated admin markup,
  # relative to the live root.
  @enforced_files [
    "../components/plugin_instance_components.ex"
  ]

  @bare_events ~w(new edit save cancel close close_modal delete remove test validate filter)

  test "admin pages follow the admin page conventions" do
    offenders =
      for path <- enforced_paths(),
          violation <- violations(File.read!(path), path) do
        "  #{Path.relative_to(path, @live_root)}: #{violation}"
      end

    assert offenders == [],
           "Admin pages drifted from the conventions in lib/mydia_web/components/README.md:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan covers every admin LiveView route" do
    pages = admin_pages()
    keys = Enum.map(pages, & &1.key)

    assert length(keys) >= 22
    assert "jobs_live" in keys
    assert "admin_subtitle_providers_live" in keys
    assert Enum.all?(pages, &(&1.files != [])), "a page resolved to no files"
    assert @pending -- keys == [], "@pending names a page with no /admin route"

    assert Enum.any?(
             pages,
             &(&1.key == "admin_subtitle_providers_live" and
                 Enum.any?(&1.files, fn f -> String.ends_with?(f, ".html.heex") end))
           )

    assert Enum.all?(Enum.map(@enforced_files, &Path.expand(&1, @live_root)), &File.regular?/1)
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

    test "counts lines without the trailing newline" do
      sixty = String.duplicate("<div></div>\n", @max_template_lines)
      assert violations(sixty, "admin_x_live/index.html.heex") == []

      assert ["template is 61" <> _] =
               violations(sixty <> "<div></div>\n", "admin_x_live/index.html.heex")
    end

    test "reports every distinct bare event" do
      content = ~S(<button phx-click="new"><form phx-submit="save"><a phx-click="new">)
      assert [a, b] = violations(content, "x.ex")
      assert a =~ ~s("new")
      assert b =~ ~s("save")
    end

    test "does not flag components that merely start with button" do
      assert violations(~S(<.button_group>x</.button_group>), "x.ex") == []
    end

    test "flags text-gray and <.button" do
      assert ["raw grey" <> _] = violations(~S(<p class="text-gray-500">), "x.ex")
      assert ["<.button>" <> _] = violations(~S(<.button class="btn">Go</.button>), "x.ex")
    end
  end

  defp enforced_paths do
    page_paths =
      for page <- admin_pages(), page.key not in @pending, path <- page.files, do: path

    page_paths ++ Enum.map(@enforced_files, &Path.expand(&1, @live_root))
  end

  # Every LiveView mounted under /admin, with the files that make up its page:
  # the module's directory, or for a single-file LiveView in the live root its
  # .ex, its .html.heex and a same-named directory of components.
  defp admin_pages do
    MydiaWeb.Router.__routes__()
    |> Enum.filter(&String.starts_with?(&1.path, "/admin/"))
    |> Enum.flat_map(fn route ->
      case route.metadata[:phoenix_live_view] do
        live when is_tuple(live) -> [elem(live, 0)]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.map(&page_files/1)
    |> Enum.reject(&is_nil/1)
  end

  defp page_files(module) do
    Code.ensure_loaded!(module)
    source = module.module_info(:compile)[:source] |> to_string() |> Path.expand()
    dir = Path.dirname(source)

    cond do
      # A dependency's LiveView mounted under /admin (the error tracker
      # dashboard) is not ours to restyle.
      not String.starts_with?(source, @live_root <> "/") ->
        nil

      dir == @live_root ->
        base = Path.rootname(source)

        %{
          key: Path.basename(base),
          files:
            [source | Path.wildcard(base <> ".html.heex")] ++
              Path.wildcard(Path.join(base, "**/*.{ex,heex}"))
        }

      true ->
        %{key: Path.basename(dir), files: Path.wildcard(Path.join(dir, "**/*.{ex,heex}"))}
    end
  end

  defp violations(content, path) do
    [
      Regex.match?(~r/class="modal(-box)?[\s"]/, content) &&
        "hand-rolled modal; use <.admin_modal>",
      template_too_long(content, path),
      content =~ "text-gray-" && "raw grey; use text-base-content/<n>",
      Regex.match?(~r/<\.button[\s>\/]/, content) &&
        "<.button>; use a raw <button> or <.row_action>"
    ]
    |> Enum.filter(& &1)
    |> Kernel.++(bare_events(content))
  end

  defp bare_events(content) do
    names = Enum.join(@bare_events, "|")

    ~r/phx-(?:click|submit|change)="(#{names})"/
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&"bare event \"#{&1}\"; name it <verb>_<thing>")
  end

  defp template_too_long(content, path) do
    lines = content |> String.trim_trailing("\n") |> String.split("\n") |> length()

    (String.ends_with?(path, ".html.heex") and lines > @max_template_lines) &&
      "template is #{lines} lines (max #{@max_template_lines}); move markup to components.ex"
  end
end
