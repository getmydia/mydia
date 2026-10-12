defmodule MydiaWeb.FormControlsInsideFormsTest do
  @moduledoc """
  The LiveView client refuses form events from a control with no enclosing
  form: `pushInput` throws "form events require the input to be inside a
  form", so the event never reaches the server. `Phoenix.LiveViewTest` does
  not check this, so a test driving `render_change` on such a control passes
  while the real page does nothing (#1120).

  This scans every template under `lib/mydia_web` and fails on a
  `select`, `input`, `textarea` or `<.input>` carrying `phx-change` outside
  a `<form>` or `<.form>`. Put `phx-change` on the form instead.

  The scan is per template: a component whose control only ever renders
  inside a parent's form in another template is a false positive. List those
  in `@allowlist` with the reason.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../lib/mydia_web", __DIR__)

  # Tag name, optional leading slash, and attributes. Attribute values in
  # `{...}` may contain `>`.
  @tag_re ~r/<(\/?)(\.form|form|select|input|textarea|\.input)\b((?:[^>{]|\{[^}]*\})*)>/
  @heex_sigil_re ~r/~H"""(.*?)"""/s
  @form_tags ["form", ".form"]

  # %{"lib/mydia_web/...ex" => "why the control is always inside a form"}
  @allowlist %{}

  test "every phx-change control sits inside a form" do
    offenders =
      @root
      |> Path.join("**/*.{ex,heex}")
      |> Path.wildcard()
      |> Enum.flat_map(&offenders_in_file/1)
      |> Enum.reject(fn {path, _line} -> Map.has_key?(@allowlist, path) end)

    assert offenders == [], """
    phx-change on a control outside a form. The LiveView client throws on
    these and the event never reaches the server. Wrap the control in
    <.form for={%{}} id="..." phx-change="..."> and move phx-change onto the form:

    #{Enum.map_join(offenders, "\n", fn {path, line} -> "  #{path}:#{line}" end)}
    """
  end

  describe "offending_lines/1" do
    test "flags a select outside a form" do
      assert offending_lines("""
             <div>
               <select name="type" phx-change="filter"></select>
             </div>
             """) == [2]
    end

    test "ignores a control inside <.form> or <form>" do
      assert offending_lines("""
             <.form for={%{}} phx-change="filter">
               <select name="type" phx-change="filter"></select>
             </.form>
             <form phx-change="x"><input name="q" phx-change="x" /></form>
             """) == []
    end

    test "flags a control after a form closes" do
      assert offending_lines("""
             <.form for={%{}}></.form>
             <input name="q" phx-change={@on_search} />
             """) == [2]
    end

    test "ignores controls without phx-change and attributes containing >" do
      assert offending_lines("""
             <input name="q" phx-click="go" class={if(@a > 1, do: "x")} />
             """) == []
    end
  end

  def offending_lines(body) do
    @tag_re
    |> Regex.scan(body, return: :index)
    |> Enum.reduce({0, []}, fn [{start, _} | groups], {depth, acc} ->
      [close, name, attrs] = Enum.map(groups, fn {s, l} -> binary_part(body, s, l) end)

      cond do
        name in @form_tags and close == "/" ->
          {depth - 1, acc}

        name in @form_tags ->
          self_closing? = attrs |> String.trim_trailing() |> String.ends_with?("/")
          {if(self_closing?, do: depth, else: depth + 1), acc}

        close == "" and depth <= 0 and attrs =~ ~r/\bphx-change\b/ ->
          {depth, [line_at(body, start) | acc]}

        true ->
          {depth, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp offenders_in_file(path) do
    source = File.read!(path)
    relative = Path.relative_to(path, Path.expand("../..", __DIR__))

    for {offset, body} <- template_bodies(source, path),
        line <- offending_lines(body) do
      {relative, line_at(source, offset) + line - 1}
    end
  end

  defp template_bodies(source, path) do
    if String.ends_with?(path, ".heex") do
      [{0, source}]
    else
      for [_whole, {start, length}] <- Regex.scan(@heex_sigil_re, source, return: :index) do
        {start, binary_part(source, start, length)}
      end
    end
  end

  defp line_at(text, byte_offset) do
    text |> binary_part(0, byte_offset) |> String.split("\n") |> length()
  end
end
