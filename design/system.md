# Waku design system (synced)

Sources: `data/static/design/tokens.css`, `type.css` (type scale), `controls.css`, `fonts.css`. Copied design files under `data/static/design/` are synced from private master — never edit them.

## Colors

| Token | Light | Dark | Usage | Source |
|---|---|---|---|---|
| `--surface-bg` | #E1E1D9 | #202020 | page ground | tokens.css |
| `--surface-paper` | ink 4% over bg | ink 4% over bg | cards, dialogs | tokens.css |
| `--surface-raised` | ink 8% over bg | ink 8% over bg | raised controls | tokens.css |
| `--surface-sunk` | ink 12% over bg | ink 12% over bg | pressed ground | tokens.css |
| `--text-ink` | #161614 | #C9CDD1 | primary text | tokens.css |
| `--text-muted` | ink 82% (8.56:1) | ink 82% | body paragraphs | tokens.css |
| `--text-faint` | ink 62% (4.59:1) | ink 62% | 12px labels | tokens.css |
| `--rule` | ink 19% | ink 19% | hairlines | tokens.css |
| `--rule-hard` | ink 42% | ink 42% | strong edges | tokens.css |
| `--accent` | #E1AE05 | #E1AE05 | fill, focus border | tokens.css |
| `--accent-fg` | #735903 (5.06:1) | #E1AE05 | accent as text | tokens.css |
| `--accent-ink` | #161614 (8.85:1 on accent) | #161614 | label on accent | tokens.css |
| `--ok` | #2B7754 | #4FBF8B | success | tokens.css |
| `--warn` | #8C5617 | #E78B23 | warning (orange, hue 32) | tokens.css |
| `--bad` | #AA2E11 | #EC6242 | error | tokens.css |
| `--input` | ink 48% over bg | ink 48% over bg | input border | type.css |
| `--scrim` | rgb(0 0 0/0.40) | rgb(0 0 0/0.55) | dialog scrim | tokens.css |

## Typography

| Token | Value | Usage | Source |
|---|---|---|---|
| `--face-sans` | Instrument Sans, Helvetica Neue, Arial | UI body | tokens.css + fonts.css |
| `--face-mono` | JetBrains Mono, ui-monospace, Menlo | code, 12px labels | tokens.css + fonts.css |
| `--face-display` | Playfair Display SC, Georgia, serif | display | tokens.css + fonts.css |
| `--text-xs/sm/base/lg/xl/2xl` | 12/13/15/20/27/36px | scale | type.css |
| `--leading-tight/snug/normal` | 1.12 / 1.3 / 1.55 | line height | type.css |
| `--tracking-label` | 0.16em | uppercase mono micro-labels | tokens.css |

## Spacing / radius / motion

- Base `--spacing: 4px`; named steps: tight 2, inside 3, between 4, group 6, section 8 (`--space-2/3/4/6/8`). No raw step 1/5/7. Source: tokens.css.
- Radius `--radius: 2px` for rectangles; `--shape-circle: 50%` (radio/avatar), `--shape-pill: 999px` (switch), `--shape-chip: 999px` (badge). Source: tokens.css.
- No shadows (`--shadow-*: none`) except one floating-menu `--shadow-md` exception. Source: tokens.css + type.css.
- Motion `--motion-fast: 0.18s`, `--motion-ease: ease`; `prefers-reduced-motion` disables. Source: tokens.css + controls.css.
- Focus: `outline 2px solid var(--accent)`, offset 2px, `:focus-visible` only. Source: controls.css.
- Disabled: color not opacity (`--disabled-fg/--disabled-edge`). Source: tokens.css.
- Stack: header 10, scrim 30, dialog 40, menu 50, toast 60, tooltip 70. Source: tokens.css.

## Component rules

- Controls share shape, duration, focus ring, pressed (sunk ground) and disabled colors via `data-slot` hooks (button, input, select-trigger, checkbox, switch, tabs-trigger, badge). Product levels (primary/secondary/destructive) stay with the component, not the contract. Source: controls.css.
- Selects in Connections modal use native `<select>` rendering via `connectionField` choice branch; bool is checkbox. Source: `data/static/js/views.js` (observed, not a token).
