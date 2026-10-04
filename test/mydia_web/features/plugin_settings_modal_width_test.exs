defmodule MydiaWeb.Features.PluginSettingsModalWidthTest do
  @moduledoc """
  The plugin settings dialog fits a phone screen when a field has a long label.

  Measured before the fix at 375x740: the `.modal-box` was 344px wide but its
  content was 612px, because daisyUI's `.label` sets `white-space: nowrap` and
  each `w-full` control stretched to its label's width. Fields and hints ran
  off the right edge.
  """
  use MydiaWeb.FeatureCase, async: false

  alias Mydia.Settings

  @moduletag :feature

  @guest_fixture Path.expand("../../support/fixtures/plugins/host_test_fixture.wasm", __DIR__)

  @long_label "Server URL (for example http://ollama.lan:11434 or https://llm.example.com/v1)"

  defp box_metrics(session) do
    eval_js(session, """
    var box = document.querySelector('#settings-modal .modal-box');
    if (!box) return null;
    return {scroll: box.scrollWidth, client: box.clientWidth};
    """)
  end

  setup do
    capabilities = %{
      "events:subscribe" => ["media_item.added"],
      "net:http" => ["discord.com"]
    }

    {:ok, _config} =
      Settings.create_plugin_config(%{
        slug: "long-label-plugin",
        name: "Long Label Plugin",
        version: "1.0.0",
        manifest: %{
          "slug" => "long-label-plugin",
          "name" => "Long Label Plugin",
          "version" => "1.0.0",
          "capabilities" => capabilities,
          "settings_schema" => [
            %{
              "key" => "base_url",
              "type" => "url",
              "label" => @long_label,
              "grants_host" => true
            },
            %{
              "key" => "shelf_enabled",
              "type" => "enum",
              "label" =>
                "Picked for you on Home (suggestions use the model for each active person, about once a day)",
              "options" => ["On", "Off"]
            }
          ]
        },
        wasm_module: File.read!(@guest_fixture),
        granted_capabilities: capabilities,
        enabled: false
      })

    :ok
  end

  @tag :feature
  test "the settings dialog does not overflow at phone width", %{session: session} do
    login_as_admin(session)

    session
    |> resize_window(375, 740)
    |> visit_liveview("/admin/plugins")

    js_click(session, "#settings-long-label-plugin")
    assert Wallaby.Browser.has_css?(session, "#plugin-settings-form")

    metrics = box_metrics(session)
    assert metrics, "the settings dialog's .modal-box was not found"

    assert metrics["scroll"] <= metrics["client"],
           "at 375px the settings dialog content was #{metrics["scroll"]}px wide " <>
             "inside a #{metrics["client"]}px box"
  end
end
