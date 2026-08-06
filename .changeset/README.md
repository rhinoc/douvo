# Release changesets

Every user-visible release must include at least one changeset file in this
directory. Use a short, user-facing English sentence and one of these types:

- `added`: New user-visible functionality.
- `changed`: Improvements to existing behavior.
- `fixed`: Bug fixes.

Example:

```markdown
---
type: fixed
---

Prevent Android recognition sessions from overlapping while a connection is closing.
```

Requirements:

- Use one non-empty sentence per file.
- Write the sentence in ASCII English.
- Do not add a Markdown list marker; the release script adds it.
- Name the file after the change, for example `fix-android-session-close.md`.

The release workflow groups pending changesets into Markdown release notes,
publishes the same notes to Sparkle and GitHub Releases, and deletes the
consumed files in the automatic release metadata commit.
