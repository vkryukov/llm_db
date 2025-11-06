# Local Authoritative Metadata + Multiple Upstream Sources

## Summary and Goals

Make the library maintainable with a local, PR-friendly authoritative repository of model metadata, while supporting multiple upstream inputs (e.g., models.dev).

**Key objectives:**
- Local data takes precedence over upstream sources
- Application-level overrides (config/behaviour) remain highest precedence
- Preserve current API and read path; only extend ingest and Mix tasks
- Enable open source contributors to submit PRs to keep model metadata up to date

## Architecture Decisions

### Source Abstraction

Introduce a small behaviour for "metadata source" to decouple ingestion from models.dev specifics:

```elixir
defmodule LLMModels.Source do
  @callback load(opts :: map()) :: 
    {:ok, %{providers: [map()], models: [map()], excludes: map()}} | 
    {:error, term()}
end
```

### Precedence Order (highest wins)

```
behaviour overrides > config overrides > local TOML > upstream merged > packaged snapshot (fallback only)
```

- **Packaged snapshot**: Fallback for offline boot and environments without local files/upstream
- **Upstream sources**: Merged from multiple JSON files (models.dev-compatible)
- **Local TOML**: Authoritative repository data (version-controlled, PR-friendly)
- **Config overrides**: Application runtime configuration
- **Behaviour overrides**: Dynamic module-based overrides

### Local File Format: TOML

**Why TOML over YAML or JSON:**
- Strict and simple syntax with fewer edge cases than YAML
- Diff-friendly and human-readable
- Well-suited for configuration and metadata
- Single small dependency acceptable for this repo's goals

### Validation

Continue using existing Zoi schemas for `Provider` and `Model`. The TOML loader:
1. Parses TOML files
2. Converts types (strings → atoms where appropriate)
3. Validates against existing Zoi schemas

### Packaging Strategy

- Keep packaged snapshot for offline boot
- Do not merge packaged with other sources when local or upstream are present (avoids duplication/drift)
- Use packaged only as fallback when neither upstream nor local data exists

### Merge Strategy

Reuse existing `Merge` functions. Extend engine to include "upstream" and "local" segments, merged sequentially with excludes and precedence rules.

## Current Architecture Review

### LLMModels.Engine

**Today:**
- Ingests three fixed sources: packaged snapshot, config overrides, behaviour overrides
- Pipeline: normalize → validate → merge → enrich → filter → index

**Changes needed:**
- Add "upstream" and "local" sources to the ingest stage
- Extend normalization/validation/merge steps to process them in order
- Keep all later stages (enrich/filter/index) unchanged

### models.dev Integration

**Today:**
- `mix llm_models.pull` fetches single models.dev JSON
- Writes `priv/llm_models/upstream.json`
- Builds `snapshot.json`
- Generates `valid_providers.ex`

**Changes needed:**
- Support multiple upstream URLs
- Save to `priv/llm_models/upstream/<name>.json`
- ETL reads and merges these files
- Snapshot generation includes local TOML data

### Zoi Schema Structure

**Existing schemas are perfect for TOML:**

- **Provider**: `id` (atom), `name`, `base_url`, `env`, `doc`, `extra`
- **Model**: `id` (string), `provider` (atom), `provider_model_id`, `name`, `family`, `release_date`, `last_updated`, `knowledge`, `limits`, `cost`, `modalities{input/output atoms}`, `capabilities` map, `tags`, `deprecated?`, `aliases`, `extra`

The Normalize step will convert strings to atoms and handle modality atoms; unknown keys stored in `extra`.

## Local Metadata Repository Layout

### Directory Structure

```
priv/llm_models/
├── openai/
│   ├── openai.toml (provider definition)
│   ├── gpt-4o.toml
│   ├── gpt-4o-mini.toml
│   └── ...
├── anthropic/
│   ├── anthropic.toml (provider definition)
│   ├── claude-3-5-sonnet.toml
│   ├── claude-3-opus.toml
│   └── ...
├── google_vertex/
│   ├── google_vertex.toml (provider definition)
│   └── ...
└── excludes.toml (optional)
```

### Example Files

#### Provider File: `openai/openai.toml`

```toml
id = "openai"
name = "OpenAI"
base_url = "https://api.openai.com"
env = ["OPENAI_API_KEY"]
doc = "https://platform.openai.com/docs"
```

#### Model File: `openai/gpt-4o-mini.toml`

```toml
id = "gpt-4o-mini"
provider = "openai"
name = "GPT-4o mini"
release_date = "2024-05-13"
family = "gpt-4o"
aliases = ["gpt-4-mini"]

[limits]
context = 128000
output = 16384

[cost]
input = 0.15
output = 0.60

[capabilities]
chat = true

[capabilities.tools]
enabled = true
streaming = true

[capabilities.json]
native = true
schema = true
```

#### Excludes File: `excludes.toml`

```toml
[openai]
patterns = ["gpt-5-*"]

[anthropic]
patterns = ["claude-instant-*"]
```

### File Conventions

- TOML keys align to Zoi schema fields
- Provider can be string (`"openai"`) and normalized to `:openai` during load
- Unknown/nested keys not in schema can be grouped under `[extra]` or passed through
- Prefer explicit lists under existing schema first

## Schema Definitions

### Reuse Existing Zoi Schemas

No schema changes required. Add TOML parsing rules:

- Convert provider string → atom via `Normalize` (safe since files are controlled)
- Convert modalities input/output strings → known atoms via `Normalize.normalize_modality_atom`
- Leave dates as strings (already accepted)
- Non-schema keys handled by existing validation (fail-fast to keep format disciplined)

### Optional Enhancement

Add helper to fold unmapped TOML top-level keys into `extra` before Zoi validation for forward compatibility.

## ETL Pipeline Changes

### New Modules

#### 1. Source Behaviour

```elixir
defmodule LLMModels.Source do
  @callback load(opts :: map()) :: 
    {:ok, %{providers: [map()], models: [map()], excludes: map()}} | 
    {:error, term()}
end
```

#### 2. Local TOML Loader

```elixir
defmodule LLMModels.Sources.Local do
  @behaviour LLMModels.Source
  
  @impl true
  def load(opts) do
    # Scans priv/llm_models/<provider>/ directories
    # Parses TOML files (provider.toml + model files)
    # Atomizes/normalizes data
    # Validates via existing Validate.* functions
    # Returns {:ok, %{providers: [...], models: [...], excludes: %{}}}
  end
end
```

#### 3. Upstream JSON Loader

```elixir
defmodule LLMModels.Sources.Upstream do
  @behaviour LLMModels.Source
  
  @impl true
  def load(opts) do
    # Reads one or more JSON files under priv/llm_models/upstream/*.json
    # Transforms to %{providers: [...], models: [...]}
    # Matches today's transform_upstream_data
    # Returns {:ok, %{providers: [...], models: [...], excludes: %{}}}
  end
end
```

### Config Additions

Extend `LLMModels.Config.get/0`:

```elixir
%{
  # New keys
  local_dir: Application.app_dir(:llm_models, "priv/llm_models"),
  upstream_sources: ["priv/llm_models/upstream.json"],  # if present, else []
  use_packaged_fallback: true,
  
  # Existing keys unchanged
  compile_embed: true,
  overrides: %{},
  overrides_module: nil,
  allow: [],
  deny: [],
  prefer: []
}
```

### Engine.ingest Updates

**Before:**
```elixir
sources = %{
  packaged: Packaged.snapshot(),
  config: config_overrides,
  behaviour: behaviour_overrides
}
```

**After:**
```elixir
sources = %{
  packaged: %{providers: [...], models: [...], excludes: %{}},
  upstream: %{providers: [...], models: [...], excludes: %{}},
  local: %{providers: [...], models: [...], excludes: %{}},
  config: %{providers: [...], models: [...], excludes: %{}},
  behaviour: %{providers: [...], models: [...], excludes: %{}},
  filters: %{allow: [...], deny: [...]},
  prefer: [...]
}
```

**Source assembly logic:**

1. **Packaged**: Load via `Packaged.snapshot()` or `%{providers: [], models: []}` if absent
2. **Upstream**: Merge all configured upstream sources (order-respecting; later sources win)
3. **Local**: Parse TOML files
4. **Config/Behaviour**: As today

### Normalize/Validate

Extend normalize/validate functions to include upstream and local exactly like packaged/config/behaviour blocks.

### Merge

Sequential merge in precedence order:

```elixir
providers =
  base_providers
  |> Merge.merge_providers(validated.local.providers)
  |> Merge.merge_providers(validated.config.providers)
  |> Merge.merge_providers(validated.behaviour.providers)

all_excludes = 
  deep_precedence_merge([
    validated.upstream.excludes,
    validated.local.excludes,
    validated.config.excludes,
    validated.behaviour.excludes
  ])

models =
  base_models
  |> Merge.merge_models(validated.local.models, all_excludes)
  |> Merge.merge_models(validated.config.models, all_excludes)
  |> Merge.merge_models(validated.behaviour.models, all_excludes)
```

**Base calculation:**
- If local or upstream have entries: use upstream merged as base
- Otherwise: use packaged snapshot as fallback
- This avoids duplicate/conflicting base data

### Enrich/Filter/Index

No changes to these stages.

## Mix Task Changes

### `mix llm_models.pull`

**Enhancements:**
- Support multiple `--url` flags
- Save each to `priv/llm_models/upstream/<slug>.json`
- Run full Engine path (including local) to generate `snapshot.json` and `valid_providers.ex`
- Keep single-URL usage working for backward compatibility

**Example:**
```bash
mix llm_models.pull --url https://models.dev/data/models.json --url https://custom.source/models.json
```

### New: `mix llm_models.local.check`

**Purpose:**
- Parse and validate TOML under `priv/llm_models/<provider>/`
- Print summary report
- No snapshot write
- Useful for PR CI validation

**Example output:**
```
Checking local metadata...
✓ Loaded 8 providers
✓ Loaded 142 models
✓ All validations passed
```

### Optional: `mix llm_models.local.sync`

**Purpose:**
- Convert current `snapshot.json` into TOML files
- One-time helper for migration/bootstrapping
- Helps kickstart the local repository

## API Changes

### Public API

**No breaking changes** to `LLMModels.*` module. Read path and structs unchanged.

### Configuration

Add optional keys to application config:

```elixir
config :llm_models,
  local_dir: "priv/llm_models",
  upstream_sources: [
    "priv/llm_models/upstream/models-dev.json",
    "priv/llm_models/upstream/custom.json"
  ],
  use_packaged_fallback: true
```

### Defaults

Preserve current behavior (packaged snapshot only) if local/upstream not present.

## Multiple Source Merging

### Strategy

Deterministic left-to-right merge with higher precedence later:

1. **Build base**: If local or upstream present, use upstream merged; else use packaged
2. **Apply local** over base (if local present)
3. **Apply config** overrides
4. **Apply behaviour** overrides

### Excludes Handling

Combine excludes from all sources with later precedence overriding earlier entries on key collisions. Final compiled excludes passed to `Merge.merge_models` control removal before enrich/filter.

### Deny/Allow Filters

Unchanged semantics; continue to apply at the end on the merged set.

## Migration Strategy

### Phase 1: Core Infrastructure (1 day)

- Introduce `LLMModels.Source`, `LLMModels.Sources.Local`, `LLMModels.Sources.Upstream`
- Extend `Engine.ingest/normalize/validate/merge` to include upstream and local
- Add config keys with sane defaults
- Update `mix llm_models.pull` to write upstream files into `priv/llm_models/upstream/`
- Add TOML dependency: `{:toml, "~> 0.7"}`

### Phase 2: Local Repository Bootstrap (1 day)

- Create local TOML skeleton from current snapshot (manual or via helper task)
- Start with minimal subset (OpenAI/Anthropic) for initial PRs
- Add `mix llm_models.local.check` for contributors/CI
- Document contribution flow in README/CONTRIBUTING

### Phase 3: Refinement (optional)

- Deprecate single `upstream.json` path in favor of `upstream_sources` list (keep backward-compat)
- Add conversion helper: `mix llm_models.local.sync` to export TOML from snapshot
- Add provenance tracking in Merge for debugging
- Add CLI to diff local TOML vs upstream to assist contributors

## Dependencies

### TOML Parser

```elixir
# mix.exs
defp deps do
  [
    {:toml, "~> 0.7"},
    # ... existing deps
  ]
end
```

**Rationale:**
- Simple, well-supported library
- Small dependency surface
- TOML is stricter and simpler than YAML (fewer edge cases)

## Effort and Scope

- **Core code** (sources + engine tweaks + config): M (1–2 days)
- **Mix tasks** updates: S (0.5–1 day)
- **Docs + examples + tests**: S (0.5–1 day)
- **Total**: M (1–2 days), low risk, fully incremental, preserves API

## Risks and Guardrails

### Risk: Duplicate Base Data

**Problem:** Packaged merged alongside upstream creates duplicates/conflicts

**Mitigation:** Use packaged only as fallback when upstream/local are empty

### Risk: Atom Creation from TOML

**Problem:** Dynamic atom creation from untrusted provider IDs

**Mitigation:** 
- Already mitigated via Normalize with unsafe mode in batch
- Files are repository-controlled
- Generate `valid_providers.ex` from final snapshot as today

### Risk: TOML Parsing Mistakes

**Mitigation:**
- Add `local.check` task for validation
- Test fixtures covering edge cases
- Fail validation fast and log dropped records (reuse existing Validate)

### Risk: Precedence Confusion

**Mitigation:**
- Codify and test precedence with unit tests
- Add precedence table to README
- Clear documentation of merge order

## Testing Strategy

### Unit Tests

- Test each source loader independently
- Test precedence order with fixtures
- Test TOML parsing edge cases
- Test merge behavior with multiple sources

### Integration Tests

- Test full ETL pipeline with local + upstream + config
- Test fallback to packaged when no other sources
- Test exclude patterns across sources

### CI Checks

- Run `mix llm_models.local.check` on PR
- Validate TOML syntax and schema compliance
- Ensure no duplicate model IDs within local repository

## Contributor Workflow

### Adding/Updating Model Metadata

1. Clone repository
2. Edit/add TOML file in `priv/llm_models/<provider>/`
3. Run `mix llm_models.local.check` to validate
4. Run `mix test` to ensure no regressions
5. Submit PR with changes

### Example PR Description

```markdown
## Add GPT-4o Mini Model

- Added `priv/llm_models/openai/gpt-4o-mini.toml`
- Updated context limits to 128k
- Added cost information: $0.15/$0.60 per million tokens

Validated with `mix llm_models.local.check` ✓
```

## Advanced Features (Future Considerations)

### Provenance Tracking

Track which source provided each field for debugging:

```elixir
# In debug builds, store metadata
%Model{
  id: "gpt-4o-mini",
  extra: %{
    provenance: %{
      id: :local,
      limits: :local,
      cost: :upstream
    }
  }
}
```

### Diff Tool

```bash
mix llm_models.diff --local --upstream models-dev
```

Shows differences between local TOML and upstream source.

### Bidirectional Sync

Automated PR generation when upstream changes conflict with local data.

### Remote Git-based Local Store

Fetch local TOML from separate Git repository for centralized management.

## Summary

This design achieves:

✅ Local authoritative metadata repository (TOML-based, PR-friendly)  
✅ Multiple upstream source support (extensible)  
✅ Clear precedence order (local > upstream > packaged)  
✅ No breaking API changes  
✅ Low implementation risk (1–2 days)  
✅ Incremental migration path  
✅ Open source contributor-friendly workflow  

The architecture reuses existing validation and merge logic while adding a clean source abstraction layer that makes the system extensible and maintainable.
