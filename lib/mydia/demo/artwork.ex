defmodule Mydia.Demo.Artwork do
  @moduledoc """
  Generates poster and backdrop images for the invented demo library.

  Each image is an SVG (gradient, a few translucent shapes, the title in large
  type) rasterised to PNG by an external renderer such as `rsvg-convert`. Colors
  derive from the title, so a title always gets the same artwork.
  """

  @sizes %{poster: {500, 750}, backdrop: {1280, 720}}
  @wrap %{poster: 12, backdrop: 26}
  @font_size %{poster: 58, backdrop: 84}

  @doc """
  Renders `title` as a `:poster` (500x750) or `:backdrop` (1280x720) PNG into
  `dir`, and returns the file name written.
  """
  @spec render(String.t(), :poster | :backdrop, Path.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def render(title, kind, dir, renderer) when kind in [:poster, :backdrop] do
    {w, h} = Map.fetch!(@sizes, kind)
    base = "#{slug(title)}-#{kind}"
    png = Path.join(dir, base <> ".png")

    svg =
      Path.join(System.tmp_dir!(), "mydia-demo-#{System.unique_integer([:positive])}-#{base}.svg")

    try do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(svg, svg(title, kind)),
           {_out, 0} <-
             System.cmd(renderer, ["-w", "#{w}", "-h", "#{h}", "-o", png, svg],
               stderr_to_stdout: true
             ) do
        {:ok, base <> ".png"}
      else
        {out, status} when is_integer(status) -> {:error, {:renderer_failed, status, out}}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e in ErlangError -> {:error, {:renderer_failed, e.original}}
    after
      File.rm(svg)
    end
  end

  @doc "A file-name safe form of `title`."
  @spec slug(String.t()) :: String.t()
  def slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc false
  def svg(title, kind) do
    {w, h} = Map.fetch!(@sizes, kind)
    hue = :erlang.phash2(title, 360)
    hue2 = rem(hue + 40 + :erlang.phash2({title, :shift}, 80), 360)
    font = Map.fetch!(@font_size, kind)
    lines = wrap(title, Map.fetch!(@wrap, kind))
    line_height = round(font * 1.15)
    first_y = round(h / 2 - (length(lines) - 1) * line_height / 2 + font / 3)

    # Backdrops carry no text: the apps draw the title over them, so a
    # rendered copy shows up as a giant ghost behind the real one.
    text =
      case kind do
        :backdrop -> ""
        :poster -> poster_text(lines, w, first_y, line_height, font)
      end

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{w}" height="#{h}" viewBox="0 0 #{w} #{h}">
      <defs>
        <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="hsl(#{hue}, 62%, 38%)"/>
          <stop offset="1" stop-color="hsl(#{hue2}, 70%, 16%)"/>
        </linearGradient>
      </defs>
      <rect width="#{w}" height="#{h}" fill="url(#bg)"/>
      <circle cx="#{round(w * 0.82)}" cy="#{round(h * 0.18)}" r="#{round(min(w, h) * 0.38)}" fill="#ffffff" fill-opacity="0.10"/>
      <circle cx="#{round(w * 0.12)}" cy="#{round(h * 0.88)}" r="#{round(min(w, h) * 0.30)}" fill="#000000" fill-opacity="0.18"/>
      <rect x="#{round(w * 0.08)}" y="#{round(h * 0.06)}" width="#{round(w * 0.5)}" height="#{round(h * 0.012)}" fill="#ffffff" fill-opacity="0.35"/>
      #{text}
    </svg>
    """
  end

  defp poster_text(lines, w, first_y, line_height, font) do
    lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, i} ->
      ~s(<text x="#{round(w / 2)}" y="#{first_y + i * line_height}" text-anchor="middle" ) <>
        ~s(font-family="sans-serif" font-weight="bold" font-size="#{font}" fill="#ffffff">) <>
        escape(line) <> "</text>"
    end)
  end

  defp wrap(title, max) do
    title
    |> String.split(" ", trim: true)
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] = acc ->
        if String.length(line) + 1 + String.length(word) <= max,
          do: [line <> " " <> word | rest],
          else: [word | acc]
    end)
    |> Enum.reverse()
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
