defmodule LLMModels.Sources.Config do
  @moduledoc """
  Loads overrides from application configuration (environment-specific tweaks).

  ## Configuration Format

      config :llm_models,
        overrides: %{
          openai: %{
            base_url: "https://staging-api.openai.com",
            models: [
              %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}},
              %{id: "gpt-4o-mini", limits: %{context: 200_000}}
            ]
          },
          anthropic: %{
            base_url: "https://proxy.example.com/anthropic",
            models: [
              %{id: "claude-3-5-sonnet", cost: %{input: 0.0, output: 0.0}}
            ]
          }
        }

  ## Structure

  - Map keyed by provider atom (`:openai`, `:anthropic`, etc.)
  - Each provider entry contains:
    - Provider field overrides (e.g., `base_url`, `name`, `env`) merged directly
    - `:models` - List of model overrides for that provider (special key)

  ## Options

  - `:overrides` - Map of provider overrides (required)

  ## Examples

      iex> Config.load(%{overrides: %{openai: %{base_url: "..."}}})
      {:ok, %{"openai" => %{id: :openai, models: [...]}, ...}}

  ## Back-compat

  Also supports legacy format:

      config :llm_models,
        overrides: %{
          providers: [...],
          models: [...]
        }
  """

  @behaviour LLMModels.Source

  @impl true
  def load(%{overrides: overrides}) when is_map(overrides) do
    cond do
      # New format: provider-keyed map
      has_provider_keys?(overrides) ->
        transform_provider_keyed(overrides)

      # Legacy format: providers/models keys
      Map.has_key?(overrides, :providers) or Map.has_key?(overrides, :models) ->
        providers = Map.get(overrides, :providers, [])
        models = Map.get(overrides, :models, [])
        {:ok, convert_to_nested_format(providers, models)}

      # Empty map
      true ->
        {:ok, %{}}
    end
  end

  def load(%{overrides: nil}), do: {:ok, %{}}
  def load(_opts), do: {:ok, %{}}

  # Private helpers

  defp has_provider_keys?(overrides) do
    overrides
    |> Map.keys()
    |> Enum.any?(fn key -> is_atom(key) and key not in [:providers, :models, :exclude] end)
  end

  defp transform_provider_keyed(overrides) do
    result =
      Enum.reduce(overrides, %{}, fn {provider_id, data}, acc ->
        # Skip legacy keys
        if provider_id in [:providers, :models, :exclude] do
          acc
        else
          # Extract models list (special key)
          provider_models = Map.get(data, :models, [])

          # Everything except :models is provider-level data
          provider_data =
            data
            |> Map.delete(:models)
            |> Map.put(:id, provider_id)
            |> Map.put(:models, provider_models)

          Map.put(acc, to_string(provider_id), provider_data)
        end
      end)

    {:ok, result}
  end

  defp convert_to_nested_format(providers, models) do
    provider_map = Map.new(providers, fn p -> {to_string(p[:id] || p["id"]), p} end)

    models_by_provider =
      Enum.group_by(models, fn m ->
        to_string(m[:provider] || m["provider"])
      end)

    Enum.reduce(provider_map, %{}, fn {provider_id, provider_data}, acc ->
      provider_models = Map.get(models_by_provider, provider_id, [])
      provider_with_models = Map.put(provider_data, :models, provider_models)
      Map.put(acc, provider_id, provider_with_models)
    end)
  end
end
