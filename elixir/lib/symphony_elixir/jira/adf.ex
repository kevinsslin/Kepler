defmodule SymphonyElixir.Jira.Adf do
  @moduledoc """
  Minimal Atlassian Document Format helpers used for prompts and comments.
  """

  @spec to_plain_text(term()) :: String.t() | nil
  def to_plain_text(nil), do: nil

  def to_plain_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def to_plain_text(%{"type" => "doc", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&node_to_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> normalize_text()
  end

  def to_plain_text(value) when is_map(value) do
    value
    |> node_to_text()
    |> normalize_text()
  end

  def to_plain_text(_value), do: nil

  @spec from_text(String.t() | nil) :: map()
  def from_text(value) when is_binary(value) do
    paragraphs =
      value
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n", trim: false)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.map(&paragraph_node/1)

    %{
      "version" => 1,
      "type" => "doc",
      "content" => paragraphs
    }
  end

  def from_text(_value), do: from_text("")

  defp paragraph_node(text) do
    %{
      "type" => "paragraph",
      "content" => paragraph_content(text)
    }
  end

  defp paragraph_content(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      parts =
        case line do
          "" -> []
          _ -> [%{"type" => "text", "text" => line}]
        end

      if index == 0 do
        parts
      else
        [%{"type" => "hardBreak"} | parts]
      end
    end)
  end

  defp node_to_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp node_to_text(%{"type" => "hardBreak"}), do: "\n"
  defp node_to_text(%{"text" => text}) when is_binary(text), do: text

  defp node_to_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map_join("", &node_to_text/1)
    |> normalize_text()
  end

  defp node_to_text(_node), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(text) when is_binary(text) do
    case text |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end
end
