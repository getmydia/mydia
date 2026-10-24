defmodule Mix.Tasks.Mydia.Ratchet do
  @moduledoc """
  Fails when the current branch adds complexity, nesting, module size or untranslated
  template text (`Mydia.Ratchet.TemplateText`) relative to its merge base.

  ## Usage

      mix mydia.ratchet
      mix mydia.ratchet --from-git-merge-base origin/master

  Extracts `lib/` at `git merge-base HEAD REF` into a temporary directory, runs
  credo with `.credo.ratchet.exs` on that tree and on the working tree, counts lines
  in both, and compares them with `Mydia.Ratchet`. Uncommitted changes are included,
  so it works as a pre-commit gate.
  """
  use Mix.Task

  alias Mydia.Ratchet

  @shortdoc "Blocks new complexity, nesting, module-size and untranslated-text debt"

  @switches [from_git_merge_base: :string]
  @config_file ".credo.ratchet.exs"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    ref = Keyword.get(opts, :from_git_merge_base, "origin/master")
    base_sha = merge_base!(ref)
    tmp_dir = Path.join(System.tmp_dir!(), "mydia-ratchet-#{System.unique_integer([:positive])}")

    try do
      extract_lib!(base_sha, tmp_dir)
      report(base_sha, tmp_dir)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp report(base_sha, tmp_dir) do
    config = Path.expand(@config_file)

    issue_regressions =
      Ratchet.complexity_regressions(
        credo_issues(tmp_dir, config),
        credo_issues(File.cwd!(), config)
      )

    size_regressions = Ratchet.size_regressions(line_counts(File.cwd!()), line_counts(tmp_dir))

    text_regressions =
      Ratchet.text_regressions(text_counts(File.cwd!()), text_counts(tmp_dir))

    Enum.each(issue_regressions, &Mix.shell().error(Ratchet.format_issue(&1)))
    Enum.each(size_regressions, &Mix.shell().error(Ratchet.format_size_regression(&1)))
    Enum.each(text_regressions, &Mix.shell().error(Ratchet.format_text_regression(&1)))

    case length(issue_regressions) + length(size_regressions) + length(text_regressions) do
      0 ->
        Mix.shell().info(
          "ratchet: no new complexity, nesting, size or untranslated-text debt since #{short(base_sha)}"
        )

      count ->
        Mix.raise(
          "ratchet: #{count} regression(s) since #{short(base_sha)}. See the lines above."
        )
    end
  end

  defp merge_base!(ref) do
    case System.cmd("git", ["merge-base", "HEAD", ref], stderr_to_stdout: true) do
      {sha, 0} ->
        String.trim(sha)

      {output, _status} ->
        Mix.raise(
          "ratchet: cannot find the merge base with #{ref}: #{output}\nRun `git fetch origin master` and try again."
        )
    end
  end

  defp extract_lib!(sha, tmp_dir) do
    File.mkdir_p!(tmp_dir)
    tar = Path.join(tmp_dir, "base.tar")

    case System.cmd("git", ["archive", "-o", tar, sha, "lib"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> Mix.raise("ratchet: git archive failed: #{output}")
    end

    :ok = :erl_tar.extract(String.to_charlist(tar), [{:cwd, String.to_charlist(tmp_dir)}])
    File.rm!(tar)
  end

  # credo exits non-zero whenever it reports issues; the JSON is what matters here.
  defp credo_issues(working_dir, config) do
    args = [
      "credo",
      "--config-file",
      config,
      "--working-dir",
      working_dir,
      "--strict",
      "--format",
      "json"
    ]

    {output, _status} = System.cmd("mix", args, env: [{"MIX_ENV", to_string(Mix.env())}])
    Ratchet.parse_credo_json(output)
  end

  defp line_counts(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Map.new(fn path ->
      {Path.relative_to(path, root), Ratchet.count_lines(File.read!(path))}
    end)
  end

  defp text_counts(root) do
    root
    |> Path.join("lib/mydia_web/**/*.{ex,heex}")
    |> Path.wildcard()
    |> Map.new(&{Path.relative_to(&1, root), Mydia.Ratchet.TemplateText.count_file(&1)})
  end

  defp short(sha), do: String.slice(sha, 0, 12)
end
