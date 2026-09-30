defmodule MydiaWeb.PwaStaticTest do
  @moduledoc """
  Files the service worker precaches. `cache.addAll` rejects the whole install
  when any of them 404s, which silently leaves the app with no worker at all.
  """
  use MydiaWeb.ConnCase, async: true

  for path <-
        ~w(/offline.html /service-worker.js /manifest.json /images/logo.svg /favicon.ico /images/icons/apple-touch-icon.png) do
    test "serves #{path} without authentication", %{conn: conn} do
      assert conn |> get(unquote(path)) |> response(200)
    end
  end
end
