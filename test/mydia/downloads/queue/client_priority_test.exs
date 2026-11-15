defmodule Mydia.Downloads.Queue.ClientPriorityTest do
  # Not async: the built-in client's runtime lives in persistent_term.
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, Runtime}
  alias Mydia.Downloads.Queue.ClientSelection

  import Mydia.SettingsFixtures

  setup do
    on_exit(fn -> BuiltIn.clear_runtime() end)
    external = download_client_config_fixture(%{type: "qbittorrent", priority: 1})
    %{external: external}
  end

  defp run_built_in(priority) do
    BuiltIn.put_runtime(%Runtime{
      api_port: 3030,
      credentials: {"mydia", "x"},
      config: %Config{priority: priority}
    })
  end

  # Issue #1422: the built-in client was hard-coded to 10, so any enabled
  # external client silently took every grab.
  test "an external client at the default priority wins over the built-in default", %{
    external: external
  } do
    run_built_in(10)
    assert ClientSelection.select_client_by_priority(:torrent).name == external.name
  end

  test "a lower built-in priority wins" do
    run_built_in(1)
    assert BuiltIn.managed?(ClientSelection.select_client_by_priority(:torrent))
  end

  test "on a tie the built-in client wins, so 1 makes it the default" do
    run_built_in(1)
    assert ClientSelection.select_client_by_priority(:torrent).name == "Built-in"
  end
end
