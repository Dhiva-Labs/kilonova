## What this changes

<!-- One or two sentences. Link the issue: Closes #123 -->

## Why

## How it was tested

<!-- Commands run, devnet steps, platforms tried. -->

## Checklist

- [ ] PR title follows Conventional Commits (`feat(scope): ...`)
- [ ] Commits are signed off (`git commit -s`)
- [ ] Tests cover the change, including failure cases for anything in `core/`
- [ ] `cargo clippy -D warnings`, `flutter analyze`, `flutter test` and the design lint pass locally
- [ ] No commented-out code, and every `TODO` links an issue
- [ ] New dependencies are explained above

**If this touches the UI**

- [ ] Follows [docs/DESIGN.md](https://github.com/Dhiva-Labs/kilonova/blob/main/docs/DESIGN.md)
- [ ] Strings are in `app_en.arb`, not hard-coded
- [ ] Screenshots attached: light and dark, desktop and Android width

**If this changes what the app sends over the network**

- [ ] `PRIVACY.md` updated with a dated changelog line, and the `privacy` label added
