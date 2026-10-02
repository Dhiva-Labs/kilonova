# Design rules

Kilonova should look like a tool someone designed on purpose, not like a
template. This file is the reference for every UI change, in the app and on
the website. Pull requests that touch UI are reviewed against it.

The mechanical rules are checked in CI by `tools/design_lint` (see
[Enforcement](#enforcement)). The rest are checked in review.

## Theme: Kilonova gold, deep space

A kilonova is the collision of two neutron stars, and it is where most of the
universe's gold is made. The accent is that gold; the surfaces are deep space.
The theme lives in color and naming only. There are no starfields, nebulae,
glows or textures.

### Color tokens

All colors are defined once, in `app/lib/theme/tokens.dart`. Widgets read them
through the theme. A `Color(...)` literal anywhere else under `app/lib/` fails
the lint.

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | `#F6F7F9` | `#0B0F17` | Page background |
| `surface` | `#FFFFFF` | `#131926` | Cards, sheets, dialogs |
| `border` | `#DDE1E8` | `#1F2633` | 1px dividers only |
| `text` | `#121722` | `#E8ECF4` | Body text and amounts |
| `textSecondary` | `#5A6275` | `#9AA3B5` | Labels, metadata, pending state |
| `accent` | `#7A5B00` | `#E8B931` | Primary buttons, links, sync orbit |
| `onAccent` | `#FFFFFF` | `#0B0F17` | Text and icons on accent fills |
| `received` | `#1E7346` | `#5FD39A` | Incoming transactions |
| `error` | `#B3261E` | `#FF8A80` | Errors |
| `testnetStrip` | `#006F80` | `#4FD3E6` | Solid strip on stagenet and testnet wallets |
| `onTestnetStrip` | `#FFFFFF` | `#0B0F17` | Text on the strip |

Contrast against `bg` and `surface` is tested in
`app/test/theme/contrast_test.dart`:

- Body text and amounts: at least 7:1 (WCAG AAA).
- Everything else that carries meaning: at least 4.5:1 (WCAG AA).

### Rules for color

- **One interactive color.** Gold marks what you can press: primary buttons,
  links, the selected item. It is never used for decoration.
- **Status is never color alone.** Received gets an arrow icon and the word
  "Received". Errors get an icon and a message. Pending has no hue at all: it
  uses `textSecondary` with a clock icon, so it never competes with gold.
- **Monero orange** (`#F26822`) appears only inside the XMR currency mark. It
  is never used for buttons or text.
- **Test networks are unmistakable.** Any stagenet or testnet screen shows a
  full-width solid `testnetStrip` with text such as "Stagenet. These coins
  have no value."

### Type

- **IBM Plex Sans** for all interface text, weights 400 and 500 only.
- **IBM Plex Mono** for amounts, addresses, transaction ids, block heights and
  sync numbers, with tabular figures so columns line up.
- Fonts are bundled in `app/assets/fonts/` with their license. They are never
  fetched at runtime.
- Emphasis comes from weight (500), never from italics or a second family.

### Space theme, done quietly

- **Sync indicator:** a thin orbit ring in `accent` with a dot on it.
  Progress is the arc length. It is static when the platform asks for reduced
  motion.
- **Telemetry style:** block heights, sync percentages and txids are set in
  Plex Mono in `textSecondary`, like a mission readout.
- **Naming** may borrow from astronomy where it says something useful
  ("Scanning block 3,412,880"). It is never decoration on buttons or headings.

### Layout and motion

- Desktop (Linux, Windows) uses two panes: wallet list and detail. Android
  uses a single pane.
- Cards are opaque `surface` blocks separated by spacing and, where needed, a
  single 1px `border` divider.
- Motion only explains a change of state (a sheet opening, a value updating),
  and respects reduced-motion settings.
- Hover and pressed states change the background to another solid token.
  They never change opacity.

### Copy

- Short, literal, second person: "You're on stagenet. These coins have no
  value."
- Use commas, colons and full stops. Do not use the em dash character
  (U+2014) in user-facing text.
- Say what a thing does: "Send XMR", "Sync from your own node".

## Banned patterns

| Banned | Do instead | Checked by |
|---|---|---|
| Purple-to-blue gradients | Flat, solid surfaces | lint (`gradient`) |
| Gradient text | Solid text color | lint (`gradient`) |
| Emojis in headings or UI strings | Words | lint (`emoji`) |
| The Inter font | IBM Plex Sans and Mono | lint (`font`) |
| Colored-border cards | Spacing and one neutral divider | review |
| Glassmorphism: blur, translucent cards | Opaque surfaces | lint (`blur`) |
| Low-contrast dark mode | AA everywhere, AAA for body text | contrast test |
| Rows of three icon boxes | Layout that follows the content | review |
| Badges or pills above headlines | A plain headline | review |
| Lucide icons | Kilonova icon set for core actions, Material Symbols for the rest | lint (`deps`) |
| Untouched shadcn/ui on the website | The same tokens as the app | review |
| Fade-in on scroll | No scroll-triggered animation | lint (`deps`) and review |
| Buttons that fade on hover | A solid hover background | review |
| The em dash character in copy | Commas, colons, full stops | lint (`dash`) |
| Buzzwords | Plain verbs | lint (`buzzword`) |
| Serif italic accent words | Weight 500 in the same family | review |
| Grain or noise overlays | Nothing | lint (`gradient`, `blur`) and review |

### Icons

Core actions (send, receive, sync, wallet, network) get their own small
Kilonova icon set with a single 1.5px stroke, added with the features that
need them. Everything else uses Material Symbols. Icon packages from the
banned list are rejected by the lint.

## Enforcement

`dart run tools/design_lint/bin/design_lint.dart` from the repo root runs
these checks and fails CI on any hit:

| Check | What it rejects | Where |
|---|---|---|
| `gradient` | `LinearGradient`, `RadialGradient`, `SweepGradient`, `linear-gradient(` and friends | `app/lib/`, `site/` |
| `blur` | `BackdropFilter`, `ImageFilter.blur`, `backdrop-filter` | `app/lib/`, `site/` |
| `color` | `Color(0x...)` / `Color.fromARGB` outside `app/lib/theme/` | `app/lib/` |
| `font` | Any reference to the Inter font | whole repo |
| `deps` | Banned packages (Lucide, scroll-reveal and animate-on-scroll libraries, Google Fonts runtime loading) | `app/pubspec.yaml`, `site/package.json` |
| `dash` | The em dash character | ARB files, `README.md`, `PRIVACY.md`, `docs/`, `site/` |
| `emoji` | Emoji characters | ARB files, Markdown headings |
| `buzzword` | Words from `tools/design_lint/buzzwords.txt` | ARB files, `README.md`, `PRIVACY.md`, `site/` |

Text inside inline code spans and fenced code blocks in Markdown is skipped,
so docs can still name what they ban.

If a rule ever needs an exception, add it to
`tools/design_lint/allowlist.txt` with a one-line reason, in its own PR.

## UI pull requests

Attach screenshots of the changed screens in light and dark mode, on desktop
and on Android width. The PR template has a checklist for this file.
