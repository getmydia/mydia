defmodule Mydia.Changelog.Entry do
  @moduledoc """
  One bundled release's notes, parsed and rendered at compile time.

  `from_file!/1` runs during compilation of `Mydia.Changelog`, so every failure
  here is a build failure rather than a runtime surprise in a shipped image.
  """

  defstruct [:version, :version_string, :html]

  @type t :: %__MODULE__{
          version: Version.t(),
          version_string: String.t(),
          html: String.t()
        }

  @doc """
  Builds an entry from a `priv/changelog/<version>.md` path.

  Raises when the filename is not bare semver, or when the markdown fails to
  render. Filenames carry no `v` prefix because `Version.parse/1` rejects it.
  """
  @spec from_file!(String.t()) :: t()
  def from_file!(path) do
    version_string = Path.basename(path, ".md")

    version =
      case Version.parse(version_string) do
        {:ok, version} ->
          version

        :error ->
          raise ArgumentError, """
          Invalid changelog filename: #{path}

          Changelog files must be named for a bare semantic version with no "v"
          prefix, for example priv/changelog/0.13.0.md
          """
      end

    %__MODULE__{
      version: version,
      version_string: version_string,
      html: path |> File.read!() |> render!(path)
    }
  end

  defp render!(markdown, path) do
    case Earmark.as_html(markdown) do
      {:ok, html, _messages} ->
        html

      {:error, _html, messages} ->
        raise ArgumentError, """
        Failed to render changelog markdown: #{path}

        #{inspect(messages)}
        """
    end
  end
end
