# Advanced Prompts

Chinese: [高级 Prompt](./advanced-prompts.zh.md)

Douvo's advanced prompt editors are available in **Settings... -> AI -> Advanced**.

Prefer structured settings first: vocabulary, punctuation, filler-word removal, emotion softening, output style, and custom output style instructions. Override the full prompts only when those controls are not expressive enough.

## Prompt Fields

| Field | Purpose | Empty behavior |
| --- | --- | --- |
| <a id="user-identity"></a>User Identity | Long-lived user role, domain, terminology preferences, or writing context used for intent and terminology disambiguation. | No user identity context is sent. |
| <a id="extra-rules"></a>Extra Rules | Extra system-prompt fragment appended after the effective built-in or custom System Prompt. | Nothing is appended. |
| <a id="system-prompt"></a>System Prompt | Defines post-processing rules, vocabulary handling, punctuation behavior, output style, and safety constraints. | Uses the built-in app system prompt. |
| <a id="user-message-template"></a>User Message Template | Wraps the raw transcript before it is sent to the selected AI backend. | Uses the built-in app user message template. |

## Template Syntax

Douvo supports a small Mustache-like syntax:

| Syntax | Meaning |
| --- | --- |
| `{{variable}}` | Inserts the variable value. Unknown variables render as empty text. |
| `{{#if variable}}...{{/if}}` | Renders the block only when the variable value is non-empty. |
| `{{#if variable}}...{{else}}...{{/if}}` | Renders the first block when non-empty, otherwise renders the `else` block. |

## Variables

| Variable | Available in | Value |
| --- | --- | --- |
| `original` | System Prompt, User Message | Raw transcript or merged ASR input text. The User Message should normally include this. |
| `selected_text` | System Prompt, User Message | Selected text used as the edit target in Selection Editing mode. Empty during normal dictation. |
| `vocabularies` | System Prompt, User Message | Candidate mappings generated from the user's vocabulary and current transcript, such as `source => target`. Empty when no candidates are found. |
| `punctuation_style` | System Prompt, User Message | Machine-readable punctuation style value, such as `complete_punctuation`. |
| `punctuation_instruction` | System Prompt, User Message | Human-readable punctuation instruction for the selected punctuation style. |
| `remove_filler_words` | System Prompt, User Message | `true` when filler-word removal is enabled, otherwise empty. |
| `soften_emotional_language` | System Prompt, User Message | `true` when emotion softening is enabled, otherwise empty. |
| `output_style_instruction` | System Prompt, User Message | Instruction generated from Output Style, Style Strength, or Custom output style. Empty when Output Style is `Original`. |
| `environment_context` | System Prompt, User Message | Optional current environment lines, such as local time, weekday, timezone, frontmost app, and window title when enabled. Empty when all context toggles are off or no value is available. |
| `user_identity` | System Prompt, User Message | Optional user-provided identity, domain, terminology preferences, or writing context. Empty when User Identity is blank. |

## Examples

Minimal user message:

```text
Raw transcript:
{{original}}

Return only the final text:
```

Conditional vocabulary block:

```text
{{#if vocabularies}}
# Possible recognition error candidates
{{vocabularies}}
{{/if}}
```

Selection Editing branch:

```text
{{#if selected_text}}
Selected text:
{{selected_text}}

Spoken edit command:
{{original}}

Return only the rewritten selected text:
{{else}}
Raw transcript:
{{original}}

Return only the final text:
{{/if}}
```

Conditional output style block:

```text
{{#if output_style_instruction}}
# Output style
{{output_style_instruction}}
{{/if}}
```

Conditional environment context block:

```text
{{#if environment_context}}
# Current environment
Use this only for disambiguation, terminology, dates, and output context. Do not add facts from it.

{{environment_context}}
{{/if}}
```

Conditional user identity block:

```text
{{#if user_identity}}
# User identity
Use this only for intent understanding and terminology disambiguation. Do not output it.

{{user_identity}}
{{/if}}
```

## Notes

- Keep prompt output requirements short and explicit.
- Prefer Extra Rules for small additions before replacing the full System Prompt.
- Do not ask the model to explain its changes; Douvo inserts the final output directly.
- Preserve code, paths, commands, URLs, names, and vocabulary terms unless the user explicitly asks to transform them.
- For translation or formatting workflows, prefer **Output Style -> Custom** before overriding the full System Prompt.
