defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.Workflow

  @render_opts [strict_variables: true, strict_filters: true]
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      workflow_source(opts)
      |> prompt_template!()
      |> parse_template!()

    assigns =
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      }
      |> Map.merge(extra_assigns(opts))

    template
    |> Solid.render!(
      assigns,
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @spec workflow_source(keyword()) :: {:ok, map()} | {:error, term()}
  defp workflow_source(opts) do
    case Keyword.get(opts, :workflow) do
      nil -> Workflow.current()
      %{} = workflow -> {:ok, workflow}
      other -> {:error, {:invalid_workflow, other}}
    end
  end

  @spec extra_assigns(keyword()) :: map()
  defp extra_assigns(opts) do
    opts
    |> Keyword.get(:extra_assigns, %{})
    |> normalize_extra_assigns()
  end

  @spec normalize_extra_assigns(term()) :: map()
  defp normalize_extra_assigns(assigns) when is_map(assigns), do: to_solid_map(assigns)
  defp normalize_extra_assigns(_assigns), do: %{}

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      @default_prompt_template
    else
      prompt
    end
  end
end
