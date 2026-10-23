defmodule Mix.Tasks.Mydia.TailwindInstall do
  @moduledoc """
  Installs the standalone Tailwind CLI where the `tailwind` package looks for
  it, unless it is already there.

      mix mydia.tailwind_install

  Stands in for `mix tailwind.install --if-missing`. That task downloads with
  `:httpc`, whose 10 KB response header limit GitHub's release download
  redirect now exceeds (its `content-security-policy` header alone is about
  9 KB), so every fresh install fails with `{:header_too_long, {:max, 10240}}`.
  This fetches the same URL with Req, which has no such limit, and writes the
  same path, so `mix tailwind mydia` finds the binary and skips its own
  installer.
  """

  use Mix.Task

  @shortdoc "Installs the Tailwind CLI with Req if it is missing"

  @impl Mix.Task
  def run(_argv) do
    # Not app.config: see Mix.Tasks.Mydia.CardigannGuest. A prod image build
    # has no values for the deployment variables config/runtime.exs requires.
    Mix.Task.run("loadpaths")
    Mix.Task.run("loadconfig")

    version = Tailwind.configured_version()
    bin_path = Tailwind.bin_path(version)

    unless File.exists?(bin_path) do
      {:ok, _} = Application.ensure_all_started(:req)
      install(url(version), bin_path)
    end
  end

  defp url(version) do
    Tailwind.default_base_url()
    |> String.replace("$version", version)
    |> String.replace("$target", Tailwind.configured_target(:mydia))
  end

  defp install(url, bin_path) do
    Mix.shell().info("Downloading Tailwind from #{url}")

    case Req.get(url, receive_timeout: 120_000, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        File.mkdir_p!(Path.dirname(bin_path))
        File.write!(bin_path, body, [:binary])
        File.chmod!(bin_path, 0o755)

      {:ok, %Req.Response{status: status}} ->
        Mix.raise("Couldn't fetch #{url}: HTTP #{status}")

      {:error, reason} ->
        Mix.raise("Couldn't fetch #{url}: #{Exception.message(reason)}")
    end
  end
end
