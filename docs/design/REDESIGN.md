# Interface redesign, round one

Kilonova's first interface was built from Material defaults: outlined text
fields with floating labels, default segmented buttons, default list tiles,
and every screen as a narrow column stuck to the top left of a wide pane.
It works, but it looks like a Flutter sample. This document is the spec for
replacing that with an interface that looks designed on purpose, within the
rules in [DESIGN.md](../DESIGN.md), which still apply in full.

The idea in one line: **an instrument, not a web page.** Strong typographic
hierarchy, hairline structure, a few large deliberate elements, mono
telemetry for anything numeric, and nothing decorative.

Reference points for feel (not to copy): Mullvad's desktop app (flat,
honest, confident), Linear's settings density, Cash App's one big number.

## What is wrong today

Seen in `app/build/screenshots` (made by `test/screenshots/screens_test.dart`):

1. **No composition.** On a 1280px window the detail pane holds a 640px
   column at the top left; 60% of the screen is empty. The unlock view is a
   text field and a button floating in that emptiness.
2. **No hierarchy.** The balance is just a bigger mono string. "Balance",
   "Full sync", the price, the spendable line, sync status and the Send
   button stack with uniform spacing. Section titles are the same weight as
   wallet names.
3. **Material defaults.** Floating-label outlined inputs, M3 button shapes,
   `SegmentedButton`, `ListTile`, the app bar with a title on the left.
4. **Numbers as debug output.** `2607.498016962174 XMR`, no thousands
   grouping, every history row at full precision. The price reads
   `USD428,151.17`.
5. **Navigation in the wrong place.** The network switcher is a segmented
   button under the "Wallets" title, where a primary tab bar would go,
   although switching networks is rare. Receiving addresses live at the
   bottom of the wallet page as a list; there is no "Receive" action next
   to "Send".
6. **Clutter.** A copy button on every history row. Three icon buttons
   crammed into the address field's suffix.

## Foundations

Everything below lives in `app/lib/theme/` and `app/lib/widgets/`. Feature
screens use these and nothing else; a feature file should never set a
radius, a border color or a font size directly.

### Tokens (`tokens.dart`)

Add to `KnColors`, in both modes, with the contrast test extended:

| Token | Light | Dark | Use |
|---|---|---|---|
| `surfaceRaised` | `#EEF0F4` | `#1A2130` | Hover and selected rows, secondary button fill, code blocks |

Everything else stays. No tinted or translucent fills anywhere.

Add `KnRadius` (`sm = 6`, `md = 8`) and use nothing else. Buttons and
inputs are `sm`; cards and dialogs are `md`.

### Type scale (`theme.dart`)

One scale, named by role, applied through `TextTheme` so widgets ask for
`titleLarge` and get the same thing everywhere:

| Role | Family | Size/line | Weight | Color |
|---|---|---|---|---|
| `displayLarge` (the balance) | Mono | 40/48 | 500 | text |
| `headlineSmall` (screen title) | Sans | 24/32 | 500 | text |
| `titleLarge` (wallet name in list, dialog title) | Sans | 18/24 | 500 | text |
| `titleMedium` (section heading) | Sans | 15/20 | 500 | text |
| `bodyLarge` | Sans | 15/22 | 400 | text |
| `bodyMedium` | Sans | 14/20 | 400 | text |
| `bodySmall` (metadata) | Sans | 13/18 | 400 | textSecondary |
| `labelLarge` (buttons) | Sans | 14/20 | 500 | inherits |
| `labelMedium` (field labels, eyebrows) | Sans | 12/16 | 500 | textSecondary |

Eyebrows are `labelMedium` in upper case with `letterSpacing: 0.6`. They
sit above a block ("BALANCE", "HISTORY", "RECEIVE") and are the only
upper-case text in the app. They are not badges: no background, no border.

Mono text (`monoStyle`) always sets `FontFeature.tabularFigures()`.

### Shapes and component themes

- `FilledButton`: height 44 (40 on phone width), horizontal padding 20,
  radius `sm`, `labelLarge`, no elevation, no shape change on hover; hover
  fills `accentHover`, pressed the same. Disabled: `surfaceRaised` fill,
  `textSecondary` label.
- Secondary button (`KnButton.secondary`): `surfaceRaised` fill, `text`
  label, same geometry. Hover: `border` fill.
- `TextButton`: `accent` label, no fill, padding 8/12, hover
  `surfaceRaised` fill. Never fades.
- Icon buttons: 36x36 hit area, 20px glyph, `textSecondary`, hover
  `surfaceRaised`.
- Inputs: see `KnField` below. The global `InputDecorationTheme` is set so
  that any stray `TextField` still looks right: filled `surface`, 1px
  `border`, radius `sm`, 2px `accent` when focused, no floating label
  (`floatingLabelBehavior: never`), 12/14 padding, hint in `textSecondary`.
- Dialogs: `surface`, radius `md`, 1px `border`, title `titleLarge`, 24px
  padding, actions right-aligned with the primary action last.
- Menus: `surface`, 1px `border`, radius `md`, items 36px tall,
  `bodyMedium`, hover `surfaceRaised`.
- Dividers: 1px `border`.
- Snackbar: `text` fill, `bg` label, radius `sm`, bottom left on desktop.
- Scrollbars: thin, `textSecondary`, only while scrolling.

### Widgets (`app/lib/widgets/`)

- `KnField`: a labelled input. Label (`labelMedium`) above, then the field,
  then an optional helper or error line (`bodySmall`, `error` color for
  errors) below. Takes `controller`, `label`, `hint`, `error`, `helper`,
  `mono` (uses Plex Mono for the value), `suffix` (a short text such as
  "XMR"), `trailing` (a row of up to three `KnIconButton`s rendered
  **below** the field, right-aligned, not inside it), `obscure`,
  `multiline`, `autofocus`, `onSubmitted`, `onChanged`, `enabled`.
  `PasswordField` and `NewPasswordFields` become thin wrappers over it.
- `KnButton`: `primary`, `secondary`, `text` variants with the geometry
  above; `expand: true` makes it full width (phone). Optional leading icon.
- `KnSegments<T>`: a 32px-tall segmented control. `surface` fill, 1px
  `border`, radius `sm`; the selected segment is an `accent` fill with
  `onAccent` text; others `text`. Used for fee priority and the network
  picker in settings. No icons.
- `KnCard`: `surface` fill, 1px `border`, radius `md`, no shadow. Optional
  `padding` (default 20). Children separated by `KnDivider` where needed.
  It is the only card.
- `Eyebrow(text)`: the upper-case section label.
- `KnRow`: a 52px list row with `leading`, `title`, `subtitle`, `trailing`,
  `selected` (`surfaceRaised` fill plus a 3px `accent` bar on the left edge)
  and `onTap` (hover `surfaceRaised`). Replaces `ListTile` everywhere.
- `KeyValue`: label left (`bodyMedium`, `textSecondary`), value right
  (mono, `text`), 36px tall, hairline between rows. For review and detail
  screens.
- `AmountText`: shows XMR amounts as **grouped** integer part, a point,
  and decimals in two parts: the first four at full color and weight, the
  remaining non-zero decimals in `textSecondary` at 0.8 of the size. Trailing
  zeros dropped; whole numbers show one decimal. `2607.498016962174` renders
  as `2,607.4980` + `16962174` (dimmed). Tapping toggles full precision at one
  size (existing behaviour) and copies nothing. `prefix` ("+", "-") and
  `size` as today; `unit` defaults to " XMR", shown in `textSecondary`.
  `formatXmr` keeps its contract (tests depend on it); add
  `formatXmrGrouped`.
- `KnIcons`: a small icon set drawn with `CustomPainter`, 1.5px stroke,
  square caps, 20px box, current color: `send` (arrow up and to the right
  leaving a short baseline), `receive` (the mirror, arrow down and left
  into a baseline), `scan` (four corner brackets with a short centre line),
  `paste` (clipboard outline), `contacts` (two overlapping circles over a
  base line), `lock` (padlock), `sync` (the orbit ring as an icon),
  `wallet` (a rounded rectangle with a notch). Exposed as
  `KnIcon(KnIcons.send, size: 20, color: ...)`. Material Symbols stay for
  everything else (settings, back, close, more, copy, edit, chevrons).
- `SyncOrbit`: unchanged, but add `size` and make the stroke 1.5px at 20px.
- `Scrim`-free sheets: on phone width, `showKnSheet(context, child)` shows
  a bottom sheet with `surface` fill, radius `md` on the top corners, a
  1px `border` on top, no drag handle pill, 20px padding. Desktop uses a
  dialog instead; `showKnDialog` picks per width.

### Price formatting

`PriceFeed.format` uses `NumberFormat.simpleCurrency(name: 'USD')` so the
result is `$428,151.17`, `€1.234,56` and so on per locale; the fallback for
codes without a symbol is `428,151.17 INR` (code after, with a space).

## Layouts

### Breakpoints

- Phone: width < 720. One pane, bottom-pinned primary actions on forms.
- Desktop: width >= 720. Sidebar plus detail pane.

### Desktop shell (`wallets_screen.dart`)

```
+--------------------+-----------------------------------------------+
| WALLETS   Mainnet v|                                               |
|                    |   Everyday                           [...]    |
| > Everyday         |   Full sync                                   |
|   2,607.4980 XMR   |                                               |
|   Savings          |   BALANCE                                     |
|   Locked           |   2,607.4980 16962174 XMR                     |
|                    |   About $428,151.17                           |
|                    |   556.8298 XMR spendable                      |
|                    |                                               |
|                    |   [ Send ]  [ Receive ]                       |
|                    |                                               |
|                    |   (o) Synced, block 5,799                     |
|                    |                                               |
|                    |   HISTORY                                     |
|                    |   +------------------------------------+      |
|                    |   | ^  -2.5071 XMR          Block 5,798 |      |
|                    |   |    To Ana                           |      |
|                    |   |------------------------------------|      |
|                    |   | v  +34.7975 XMR         Block 5,797 |      |
|                    |   |    Mined, locked                    |      |
|                    |   +------------------------------------+      |
| [+ Add wallet]     |                                               |
| [Settings]         |                                               |
+--------------------+-----------------------------------------------+
```

- Sidebar: 280px, `surface` fill, 1px `border` on the right, full height.
  Top: `Eyebrow("WALLETS")` and, on the right, the network as a quiet menu
  button ("Mainnet" with a small chevron, `bodyMedium`); choosing stagenet
  or testnet switches the list and shows the test-network strip across the
  top of **both** panes. Below: wallet rows (`KnRow`): name in `titleLarge`
  at 16px; second line in mono `bodySmall`: the grouped balance if the
  wallet is unlocked, else "Locked" with `KnIcons.lock` at 14px. Mode and
  view-only are not shown in the list; they are in the detail header.
  Bottom, pinned: two `KnButton.text` rows, "Add wallet" (opens the
  create/restore menu) and "Settings". No app bar on desktop.
- Detail pane: `bg` fill, 40px padding, content max width 760, left
  aligned. No app bar; the header is part of the content: wallet name
  (`headlineSmall`), one line under it in `bodySmall` with mode, view-only
  and, when prices are on, nothing else; the "more" menu button top right.
- Empty detail (no wallet chosen): centered `SyncOrbit` at 48px in
  `border` color above "Choose a wallet" in `bodyMedium` `textSecondary`.
  Nothing else.
- Unlock: centered block, 360px wide: wallet name (`headlineSmall`),
  `KnField(label: "Password", obscure)`, `KnButton.primary("Unlock",
  expand)`, and the biometric option as a `KnButton.text` below. Errors
  under the field. Vertically centered in the pane.

### Wallet page (`wallet_view.dart`, `sync_panel.dart`, `history_list.dart`)

- Balance block: `Eyebrow("BALANCE")`, `AmountText` at `displayLarge`,
  then one `bodySmall` line: fiat ("About $428,151.17") when on; then one
  mono `bodySmall` line "556.8298 XMR spendable" only when it differs from
  the total; pool incoming as a third line "+0.25 XMR waiting for a block"
  in `received` color.
- Actions: `KnButton.primary("Send", icon: send)` and
  `KnButton.secondary("Receive", icon: receive)` side by side, 12px gap.
  View-only wallets show only Receive.
- Sync line: `SyncOrbit` 20px, then mono `bodySmall`: "Synced, block
  5,799" / "Scanning block 3,412 of 5,799" / "Connecting to node.example"
  / failure prompts as today (they keep their action buttons, now
  `KnButton.text`). The LWS consent and server prompts keep their copy.
- History: `Eyebrow("HISTORY")` then a `KnCard` with rows; the card is
  omitted for the empty state, which is one `bodyMedium` line. Row: a
  20px direction icon (`KnIcons.receive` in `received`, `KnIcons.send` in
  `text`, a Material `schedule` icon in `textSecondary` while pending),
  amount with sign in mono `bodyLarge` (received in `received`), right
  side mono `bodySmall` "Block 5,798" or "Pending"; second line
  `bodySmall`: note if any, else "To Ana" / "Mined" / "Received" plus
  ", locked" while locked. No copy button; rows open the details screen.
- Receiving addresses leave this page.

### Receive (`receive_screen.dart`, new)

Opened by the Receive button. Desktop: a dialog 520px wide; phone: a full
screen. Content: the chosen address as a QR (same rendering as today) in a
`surface` block, the address in mono `bodySmall` with a copy button, the
optional amount `KnField(suffix: "XMR")`, "Copy request" as text button.
Below, `Eyebrow("ADDRESSES")` and the subaddress list as `KnRow`s (label
or "Primary address" / "Subaddress 3", address shortened to 12+12 chars in
mono), tapping one selects it for the QR; "New address" as a text button at
the end. Edit label from a row's trailing edit button.

### Send (`send_screen.dart`)

- Desktop: content max width 560, left aligned, 40px padding, no app bar:
  header "Send" (`headlineSmall`) with a back text button "Cancel" on the
  right; phone: app bar with back arrow.
- Spendable line at the top in mono `bodySmall`.
- Each recipient: `KnField(label: "To", hint: "Monero address or payment
  request", mono, multiline, trailing: [contacts, scan, paste])` and
  `KnField(label: "Amount", suffix: "XMR", mono)`. The trailing row sits
  under the address field, right-aligned, icons only with tooltips.
  Additional recipients get `Eyebrow("RECIPIENT 2")` and a "Remove" text
  button on the same line.
- Under the amount: "Send everything" as a text button on the right.
- Fee: `Eyebrow("FEE")`, `KnSegments` (Low / Normal / High / Urgent), help
  line in `bodySmall`.
- Primary: desktop `KnButton.primary("Review")` left aligned; phone pinned
  to the bottom with 16px padding and a hairline above, `expand`.
- Review: a `KnCard`: `Eyebrow("SENDING")`, each payment as `AmountText`
  (`titleLarge` size) over the address (mono `bodySmall`, contact name in
  `bodyMedium` above it when known), then `KeyValue` rows: Network fee,
  Leaves this wallet (weight 500), Change back; then "Published through
  host" in `bodySmall`. The high-fee warning as an `ErrorLine` above the
  rows. Then outside the card: `KnField(label: "Password", obscure)`,
  then `KnButton.primary("Send now")`, `KnButton.text("Change")`,
  biometric option. The unaudited / test-network note stays under the
  title in `bodySmall`.

### Transaction details, address book, settings, create, restore

Apply the same primitives:

- Details: `AmountText` at `headlineSmall` size with direction and block
  under it; `Eyebrow("TRANSACTION ID")` with the id in mono and a copy
  button on the same line; `KnField(label: "Note", multiline)` with a
  "Save" text button appearing when edited; `Eyebrow("PAID TO")` rows;
  the transaction-key block as a `KnCard` with the help text and the
  button.
- Address book: `KnRow`s in a `KnCard`; the add/edit dialog uses
  `KnField`s.
- Settings home: a `KnCard` with `KnRow`s (icon, title, subtitle,
  chevron). Sub-screens: content max width 640, `Eyebrow`s for sections,
  `KnField`s, `KnSegments` for the network picker, `KnRow`s for lists with
  the selected node marked by the gold bar. Switches keep Material's
  `Switch`, themed `accent`.
- Create and restore: `KnField`s; the seed grid keeps its layout but
  numbers go mono `textSecondary`; step titles `headlineSmall`; primary
  action bottom-pinned on phone.

### Phone

- Wallet list: app bar with "Wallets" and the network menu button on the
  right; rows as in the sidebar; "Add wallet" as a bottom-pinned
  `KnButton.secondary(expand)`; settings via the app bar action.
- Wallet page: app bar with the name and the more menu; the balance block
  and the two action buttons side by side at full width; then history.
- Send, receive, details: full screens with bottom-pinned primary actions.
- The test-network strip stays full width under the app bar.

## Motion

None added. Hover and pressed states are solid fills. Route transitions are
Flutter's defaults for the platform.

## Copy changes

- "Up to date at block N" becomes "Synced, block N".
- "N XMR can be spent now" becomes "N XMR spendable".
- "Select a wallet to open it." becomes "Choose a wallet".
- "Recipient address" becomes "To".
- Everything else stays. Tests that match these strings are updated with
  them.

## Work split

1. **Foundations** (one agent, Opus): tokens, theme, every widget above,
   `AmountText`, `PriceFeed.format`, contrast and widget tests. Nothing in
   `features/` changes except what the type scale forces. Done when
   `tools/check.sh` passes and `test/widgets/` covers the new widgets.
2. **Wallet home and receive** (Sonnet): `features/wallets/`,
   `features/wallet/` except `tx_details_screen.dart`, the new receive
   screen, and their tests.
3. **Send, details, address book** (Sonnet): `features/send/`,
   `features/wallet/tx_details_screen.dart`, `features/book/`, tests.
4. **Settings, create, restore** (Sonnet): `features/settings/`,
   `features/create/`, `features/restore/`, tests.
5. **Review** (Fable): screenshots in both modes at both widths, fixes,
   `DESIGN.md` updated with the primitives, merge to main.

Steps 2 to 4 run in parallel in their own worktrees after step 1 lands,
each adding its own strings to `app_en.arb` (merged by hand).

## Done means

- Every screen in `test/screenshots/screens_test.dart` looks intended at
  1280x860 and 412x915, light and dark.
- No `TextField`, `ListTile`, `SegmentedButton`, `FilledButton`,
  `OutlinedButton` or `TextButton` is used directly in `features/`; the
  design lint gains a `widgets` check for this.
- `tools/check.sh --regtest` passes.
