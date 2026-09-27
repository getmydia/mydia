defmodule Mydia.ApplicationObanConfigTest do
  use ExUnit.Case, async: false

  alias Mydia.Application, as: App
  alias Mydia.Config.Schema

  setup do
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  test "children/1 overlays oban runtime config when Oban is enabled" do
    fake_config = %Schema{
      oban: %Schema.Oban{poll_interval: 3333, max_age_days: 12}
    }

    Application.put_env(:mydia, :runtime_config, fake_config)

    base_oban = [
      repo: Mydia.Repo,
      queues: [default: 5],
      plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]
    ]

    children = App.children(base_oban)

    assert {Oban, oban_opts} =
             Enum.find(children, fn
               {Oban, _} -> true
               _ -> false
             end)

    assert oban_opts[:stage_interval] == 3333
    {Oban.Plugins.Pruner, pruner_opts} = List.keyfind(oban_opts[:plugins], Oban.Plugins.Pruner, 0)
    assert pruner_opts[:max_age] == 12 * 86_400
  end
end
