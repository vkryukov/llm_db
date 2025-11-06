defmodule LLMModels.Runtime do
  @moduledoc """
  Runtime filtering and preference updates without running the full Engine.

  Apply runtime overrides to an existing snapshot:
  - Recompile and reapply filters (allow/deny patterns)
  - Update provider preferences

  Unlike the full Engine pipeline, this does not add new providers/models,
  run normalization/validation, or modify provider/model data.

  ## Example

      snapshot = LLMModels.Store.snapshot()
      overrides = %{
        filters: %{
          allow: %{openai: ["gpt-4"]},
          deny: %{}
        },
        prefer: [:openai, :anthropic]
      }

      {:ok, updated_snapshot} = LLMModels.Runtime.apply(snapshot, overrides)
  """

  alias LLMModels.{Config, Engine}

  @doc """
  Applies runtime overrides to an existing snapshot.

  ## Parameters

  - `snapshot` - The current snapshot map
  - `overrides` - Map with optional `:filters` and `:prefer` keys

  ## Override Options

  - `:filters` - %{allow: patterns, deny: patterns} to recompile and reapply
  - `:prefer` - List of provider atoms to update preference order

  ## Returns

  - `{:ok, updated_snapshot}` - Success with updated snapshot
  - `{:error, reason}` - Validation or processing error
  """
  @spec apply(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def apply(snapshot, overrides) when is_map(snapshot) do
    case validate_and_prepare_overrides(overrides) do
      {:ok, prepared} ->
        apply_overrides(snapshot, prepared)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_and_prepare_overrides(nil), do: {:ok, %{}}
  defp validate_and_prepare_overrides(overrides) when overrides == %{}, do: {:ok, %{}}

  defp validate_and_prepare_overrides(overrides) when is_map(overrides) do
    with :ok <- validate_filters(overrides[:filters]),
         :ok <- validate_prefer(overrides[:prefer]) do
      {:ok, overrides}
    end
  end

  defp validate_filters(nil), do: :ok
  defp validate_filters(%{} = filters) when map_size(filters) == 0, do: :ok

  defp validate_filters(%{allow: allow, deny: deny}) do
    cond do
      not is_map(allow) and allow != :all ->
        {:error, "filters.allow must be a map or :all"}

      not is_map(deny) ->
        {:error, "filters.deny must be a map"}

      true ->
        :ok
    end
  end

  defp validate_filters(_), do: {:error, "filters must be %{allow: ..., deny: ...}"}

  defp validate_prefer(nil), do: :ok
  defp validate_prefer([]), do: :ok

  defp validate_prefer(prefer) when is_list(prefer) do
    if Enum.all?(prefer, &is_atom/1) do
      :ok
    else
      {:error, "prefer must be a list of atoms"}
    end
  end

  defp validate_prefer(_), do: {:error, "prefer must be a list of atoms"}

  defp apply_overrides(snapshot, overrides) do
    snapshot
    |> maybe_update_filters(overrides[:filters])
    |> maybe_update_prefer(overrides[:prefer])
    |> wrap_ok()
  end

  defp maybe_update_filters(snapshot, nil), do: snapshot
  defp maybe_update_filters(snapshot, filters) when map_size(filters) == 0, do: snapshot

  defp maybe_update_filters(snapshot, filters) do
    compiled_filters =
      Config.compile_filters(
        Map.get(filters, :allow, :all),
        Map.get(filters, :deny, %{})
      )

    all_models = Map.values(snapshot.models) |> List.flatten()
    filtered_models = Engine.apply_filters(all_models, compiled_filters)
    indexes = Engine.build_indexes(snapshot.providers, filtered_models)

    %{
      snapshot
      | filters: compiled_filters,
        models_by_key: indexes.models_by_key,
        models: indexes.models_by_provider,
        aliases_by_key: indexes.aliases_by_key
    }
  end

  defp maybe_update_prefer(snapshot, nil), do: snapshot
  defp maybe_update_prefer(snapshot, []), do: snapshot

  defp maybe_update_prefer(snapshot, prefer) when is_list(prefer) do
    %{snapshot | prefer: prefer}
  end

  defp wrap_ok(snapshot), do: {:ok, snapshot}
end
