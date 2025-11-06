defmodule LLMModels.Sources.Remote do
  @moduledoc """
  Loads model metadata from one or more JSON files (models.dev-compatible format).

  Supports multiple files with later files overriding earlier files within this source layer.

  ## Options

  - `:paths` - List of file paths to load (required)
  - `:file_reader` - Function for reading files (default: `&File.read!/1`)

  ## Examples

      iex> Remote.load(%{paths: ["priv/models.json"]})
      {:ok, %{"openai" => %{id: :openai, models: [...]}, ...}}

      iex> Remote.load(%{paths: ["base.json", "overrides.json"]})
      {:ok, %{"openai" => %{id: :openai, models: [...]}, ...}}  # overrides.json wins

  ## Error Handling

  Individual file failures are logged and skipped. Returns `{:error, :no_data}`
  only if no files could be loaded.
  """

  require Logger

  @behaviour LLMModels.Source

  alias LLMModels.Merge

  @impl true
  def load(%{paths: paths} = opts) when is_list(paths) do
    file_reader = Map.get(opts, :file_reader, &File.read!/1)

    {data, loaded_count} =
      Enum.reduce(paths, {%{}, 0}, fn path, {acc, count} ->
        case load_json_file(path, file_reader) do
          {:ok, content} ->
            normalized = normalize_remote(content)
            {merge_layer(acc, normalized), count + 1}

          {:error, reason} ->
            Logger.warning("Failed to load remote source #{path}: #{inspect(reason)}")
            {acc, count}
        end
      end)

    if loaded_count == 0 do
      {:error, :no_data}
    else
      {:ok, data}
    end
  end

  def load(%{paths: []}), do: {:error, :no_data}
  def load(_opts), do: {:error, :paths_required}

  # Private helpers

  defp load_json_file(path, file_reader) do
    try do
      content = file_reader.(path)
      decoded = Jason.decode!(content)
      {:ok, decoded}
    rescue
      e in File.Error ->
        {:error, {:file_error, e.reason}}

      e in Jason.DecodeError ->
        {:error, {:json_error, e.data}}

      e ->
        {:error, {:unexpected, e}}
    end
  end

  defp normalize_remote(content) when is_map(content) do
    providers = Map.get(content, "providers", [])
    models = Map.get(content, "models", [])
    convert_to_nested_format(providers, models)
  end

  defp normalize_remote(_), do: %{}

  defp convert_to_nested_format(providers, models) do
    provider_map = Map.new(providers, fn p -> {to_string(p["id"] || p[:id]), p} end)

    models_by_provider =
      Enum.group_by(models, fn m ->
        to_string(m["provider"] || m[:provider])
      end)

    Enum.reduce(provider_map, %{}, fn {provider_id, provider_data}, acc ->
      provider_models = Map.get(models_by_provider, provider_id, [])
      provider_with_models = Map.put(provider_data, "models", provider_models)
      Map.put(acc, provider_id, provider_with_models)
    end)
  end

  defp merge_layer(acc, new_layer) do
    Map.merge(acc, new_layer, fn _key, old_provider, new_provider ->
      old_models = Map.get(old_provider, "models", [])
      new_models = Map.get(new_provider, "models", [])
      merged_models = Merge.merge_models(old_models, new_models, %{})

      old_provider
      |> Map.merge(new_provider)
      |> Map.put("models", merged_models)
    end)
  end
end
