defmodule MetadataRelay.Feedback.IssueDraft do
  @moduledoc """
  Turns a feedback submission into a GitHub issue draft.

  Pure. Issues on the target repository are public, so the draft deliberately
  omits `contact`, `source_ip`, and `instance_id`. `mydia_version` is included
  because it is the one field that consistently earns its place in a bug report.
  """

  alias MetadataRelay.Feedback.Submission

  @title_limit 72

  @labels %{
    "bug" => ["bug"],
    "idea" => ["enhancement"],
    "question" => ["question"]
  }

  defstruct [:title, :body, :labels]

  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          labels: [String.t()]
        }

  @spec from_submission(Submission.t(), String.t() | nil) :: t()
  def from_submission(%Submission{} = submission, dashboard_url) do
    %__MODULE__{
      title: title(submission),
      body: body(submission, dashboard_url),
      labels: Map.get(@labels, submission.type, [])
    }
  end

  defp title(%Submission{message: message, type: type}) do
    message
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/\s+/, " ") |> String.trim()))
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> "Feedback: #{type}"
      line -> truncate(line)
    end
  end

  defp truncate(line) do
    if String.length(line) > @title_limit do
      String.slice(line, 0, @title_limit) <> "…"
    else
      line
    end
  end

  defp body(submission, dashboard_url) do
    [
      defang(submission.message),
      "",
      "---",
      provenance(submission),
      backlink(submission, dashboard_url)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc false
  # Feedback is submitted anonymously and the issue is public, so a reporter
  # could otherwise make a maintainer's account ping arbitrary people with
  # `@someone` or backlink an unrelated issue with `#123`. GitHub's own escape
  # is an empty HTML comment: it renders as the original text but stops the
  # mention and the autolink.
  def defang(nil), do: nil

  def defang(message) do
    message
    |> to_string()
    |> String.replace(~r/(?<![\w`])@(?=[A-Za-z0-9])/, "@<!---->")
    # owner/repo#123 cross-references another repository and backlinks it there.
    # It has to come first: the bare rule below refuses to touch a `#` that
    # follows a word character, which is exactly what this form looks like.
    |> String.replace(~r"([\w.\-]+/[\w.\-]+)#(?=\d)", "\\1#<!---->")
    |> String.replace(~r/(?<![\w`&])#(?=\d)/, "#<!---->")
  end

  defp provenance(%Submission{mydia_version: nil}), do: "Reported via in-app feedback."

  defp provenance(%Submission{mydia_version: version}) do
    case String.trim(to_string(version)) do
      "" -> "Reported via in-app feedback."
      trimmed -> "Reported via in-app feedback from Mydia #{trimmed}."
    end
  end

  defp backlink(submission, dashboard_url) do
    case MetadataRelay.Feedback.submission_url(submission, dashboard_url) do
      nil -> nil
      url -> "Feedback: " <> url
    end
  end
end
