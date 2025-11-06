# Snapshot V2 Schema Refactor - Engine Changes

## Summary

Refactored `LLMModels.Engine` to output the new simplified snapshot schema v2, which nests models under their providers for better organization and more intuitive structure.

## Changes Made

### 1. Engine.finalize/1 (`lib/llm_models/engine.ex`)

**Modified to build nested v2 structure:**
- Added `build_nested_providers/2` function to create the nested provider → models hierarchy
- Changed snapshot output to include `version: 2` and `generated_at` at top level
- Moved `providers` from flat list to nested map structure: `%{provider_id => %{...provider_fields, models: %{model_id => model}}}`
- Kept internal indexes (`providers_by_id`, `models_by_key`, `aliases_by_key`) for runtime use (not serialized)
- Removed `prefer` from snapshot output (kept internally)

**New snapshot structure:**
```elixir
%{
  # Internal indexes (not serialized to JSON)
  providers_by_id: %{atom => Provider.t()},
  models_by_key: %{{atom, String.t()} => Model.t()},
  aliases_by_key: %{{atom, String.t()} => String.t()},
  filters: %{allow: compiled, deny: compiled},
  prefer: [atom],
  
  # V2 output structure (serialized to JSON)
  version: 2,
  generated_at: "2025-11-06T12:34:56Z",
  providers: %{
    atom_provider_id => %{
      id: atom,
      name: string,
      base_url: string,
      ...other_provider_fields,
      models: %{
        string_model_id => %{
          id: string,
          name: string,
          family: string,
          provider: atom,  # kept for convenience
          ...other_model_fields
        }
      }
    }
  }
}
```

**Key transformations:**
- Models are grouped by provider and nested under `providers[provider_id].models[model_id]`
- Provider field is kept in models for convenience (though redundant in nested structure)
- All maps are sorted alphabetically by key for stable diffs
- Indexes are built first, then nested structure is created for serialization

### 2. Engine.build_nested_providers/2 (new function)

Created new function to transform flat provider/model lists into nested structure:
- Groups models by provider using `models_by_provider` index
- Creates a map of models keyed by `model.id` for each provider
- Sorts both provider keys and model keys alphabetically
- Returns `%{provider_id => %{...provider_fields, models: %{...}}}`

### 3. Engine.ensure_viable/1

Updated to work with nested structure:
- Changed from `Map.values(snapshot.models) |> List.flatten()` to iterating over nested providers
- Counts total models by summing `map_size(provider.models)` across all providers

### 4. Mix.Tasks.LlmModels.Build (`lib/mix/tasks/llm_models.build.ex`)

**Updated save_snapshot/1:**
- Changed from flat `{providers: [...], models: [...]}` to nested v2 schema
- Output structure: `{version: 2, generated_at: timestamp, providers: nested_map}`
- Uses `map_with_string_keys/1` to convert atom keys to strings for JSON
- Updated console message to show version number

**Updated print_summary/1:**
- Changed from `length(snapshot.providers)` to `map_size(snapshot.providers)`
- Changed model count to sum `map_size(provider.models)` across all providers

**Updated generate_valid_providers/1:**
- Changed from `Enum.map(snapshot.providers, & &1.id)` to `Map.keys(snapshot.providers)`
- Simplified since providers is now a map with provider IDs as keys

## Breaking Changes for Consumers

### Store Module (not yet updated)
The Store module currently expects the old structure and will need updates:
- Loading snapshot: needs to handle v2 nested structure
- Accessing models: can no longer use `snapshot.models` directly
- Must extract models from nested `snapshot.providers[provider_id].models`

### Runtime Consumers (not yet updated)
Any code that directly accesses snapshot structure will break:
- ❌ `snapshot.models` - no longer exists in serialized output
- ❌ `snapshot.meta` - replaced with top-level `generated_at` and `version`
- ✅ `snapshot.providers` - now a map instead of list
- ✅ Internal indexes still work: `providers_by_id`, `models_by_key`, `aliases_by_key`

### Tests (3 failures)
The following tests need updating to match new structure:

1. **`test/llm_models/engine_test.exs:48`** - "runs complete ETL pipeline with test data"
   - Expects `snapshot.models` key (no longer exists in v2)
   - Expects `snapshot.meta` key (replaced with top-level fields)

2. **`test/llm_models/engine_test.exs:63`** - "snapshot has correct metadata structure"
   - Expects `snapshot.meta.epoch` and `snapshot.meta.generated_at`
   - Should now check `snapshot.generated_at` and `snapshot.version`

3. **`test/llm_models/engine_test.exs:93`** - "builds models by provider index correctly"
   - Expects `snapshot.models` to be `%{provider => [models]}`
   - Should check `snapshot.providers[provider].models` instead (or keep using internal `models_by_provider` index)

## JSON Output Example

The new snapshot.json structure will look like:
```json
{
  "version": 2,
  "generated_at": "2025-11-06T16:37:12Z",
  "providers": {
    "mistral": {
      "id": "mistral",
      "name": "Mistral",
      "base_url": "https://api.mistral.ai/v1",
      "models": {
        "codestral-latest": {
          "id": "codestral-latest",
          "name": "Codestral",
          "family": "codestral",
          "provider": "mistral",
          "aliases": ["codestral"],
          "deprecated": false
        }
      }
    }
  }
}
```

## Next Steps

1. ✅ **Engine outputs v2 structure** (DONE)
2. ⏳ **Update Engine tests** to expect new structure
3. ⏳ **Update Store module** to load and use v2 snapshots
4. ⏳ **Update Packaged module** to work with v2 structure
5. ⏳ **Regenerate snapshot.json** with `mix llm_models.build`
6. ⏳ **Update all integration tests** that depend on snapshot structure
7. ⏳ **Update documentation** to reflect v2 schema

## Migration Strategy

**Option 1: Version detection (recommended)**
- Store checks `snapshot.version` field
- If version == 2, use new nested structure
- If no version or version == 1, use old flat structure
- Allows gradual rollout

**Option 2: Big bang**
- Update all consumers at once
- Regenerate snapshot
- No backward compatibility
- Faster but riskier

## Files Modified

- `lib/llm_models/engine.ex` - Core v2 structure generation
- `lib/mix/tasks/llm_models.build.ex` - JSON serialization and summaries
- `SNAPSHOT_V2_REFACTOR.md` - This documentation

## Test Results

```
Finished in 0.5 seconds (0.3s async, 0.1s sync)
37 doctests, 458 tests, 3 failures
```

**Failures:**
- All 3 failures are in `EngineTest` due to changed snapshot structure
- All other tests (455/458) pass, indicating indexes and core functionality work correctly
- Failures are expected and need test updates to match v2 schema
