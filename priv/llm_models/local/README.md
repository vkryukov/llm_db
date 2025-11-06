# Local TOML Model Definitions

This directory contains example TOML files for defining custom LLM providers and models.

## Directory Structure

```
priv/llm_models/local/
├── openai/
│   ├── provider.toml         # Provider definition
│   ├── gpt-4o.toml           # Model
│   └── gpt-4o-mini.toml      # Model
├── anthropic/
│   ├── provider.toml
│   └── claude-3-5-sonnet.toml
└── custom/
    ├── provider.toml
    └── my-model.toml
```

## File Naming Convention

- **Provider files**: Must be named `provider.toml`
- **Model files**: Can be any name ending in `.toml` (e.g., `gpt-4o.toml`)

## Provider TOML Schema

```toml
id = "provider-id"           # Required: atom-compatible string
name = "Provider Name"       # Optional: display name
base_url = "https://..."     # Optional: API base URL
doc = "https://..."          # Optional: documentation URL
env = ["API_KEY_VAR"]        # Optional: environment variable names

[extra]                      # Optional: custom fields
custom_field = "value"
```

## Model TOML Schema

```toml
id = "model-id"                      # Required: unique model identifier
provider = "provider-id"             # Required: links to provider
provider_model_id = "api-model-id"   # Optional: provider's model ID
name = "Model Display Name"          # Optional
family = "model-family"              # Optional: model family/series
release_date = "2024-01-15"         # Optional: ISO date
knowledge = "2024-01"               # Optional: knowledge cutoff
tags = ["tag1", "tag2"]             # Optional: categorization tags
aliases = ["alias1"]                # Optional: alternative names
deprecated = false                  # Optional: deprecation status

[limits]
max_input_tokens = 128000           # Optional
max_output_tokens = 4096            # Optional

[cost]
input_per_1m = 1.00                 # Optional: cost per 1M input tokens
output_per_1m = 2.00                # Optional: cost per 1M output tokens

[modalities]
input = ["text", "image"]           # Optional: input types
output = ["text"]                   # Optional: output types

[capabilities]
streaming = true                    # Optional
function_calling = true             # Optional
vision = true                       # Optional
prompt_caching = false             # Optional

[extra]                             # Optional: custom fields
deployment_id = "prod-001"
```

## Usage

1. Create a directory named after your provider ID
2. Add a `provider.toml` file with provider metadata
3. Add model TOML files for each model
4. Configure the Local source in your application:

```elixir
config :llm_models,
  sources: [
    {LLMModels.Sources.Local, %{dir: "priv/llm_models/local"}},
    # ... other sources
  ]
```

5. Run `mix llm_models.build` to generate the snapshot

## Examples

See the example files in this directory:
- `openai/` - OpenAI provider with GPT-4o models
- `anthropic/` - Anthropic provider with Claude 3.5 Sonnet
- `custom/` - Custom provider template

## Notes

- All IDs should be lowercase with underscores (e.g., `my_provider`, not `my-provider`)
- Atoms can contain dashes but underscores are normalized
- The `provider` field in model files is automatically added if missing (uses directory name)
- Parse errors in individual files are logged but don't stop processing
