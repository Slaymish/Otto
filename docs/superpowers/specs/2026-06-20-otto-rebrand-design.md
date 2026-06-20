# Otto — rebrand & repositioning design

**Date:** 2026-06-20
**Status:** Approved
**Scope:** Establish this project as its own thing ("Otto"), independent of its
voice-os origin. Full rename, fresh README, licensing/authorship.

## Vision

Otto is a **personal, native-feeling ambient assistant for the Mac — voice or
text — that learns the user's workflows and compounds, getting better the more
it is used.** UX-first, daily-driver quality, not a gimmick.

This replaces the original framing ("a hackable starter kit built for a video;
clone it and hand it to your coding agent"). The README is rewritten around
*using* Otto, not cloning it.

## Rename mapping (full)

| From | To | Notes |
|---|---|---|
| `VOICEOS_` env prefix (83 hits) | `OTTO_` | Read via a fallback helper so old `VOICEOS_` vars still resolve (warn once, never crash) |
| `VOICEOS_PROJECT_ROOT` | `OTTO_PROJECT_ROOT` | + fallback |
| `VoiceOS.app` | `Otto.app` | |
| bundle id `com.voiceos.app` | `com.otto.app` | Resets macOS Accessibility + Mic grants (accepted) |
| `VoiceOSApp.swift`, `VoiceOSApp` struct, `VoiceOS.entitlements`, Info.plist strings, scheme, `.xcodeproj`, nested `VoiceOS/VoiceOS/` dirs | `Otto*` equivalents | Xcode project internal path refs updated too |
| log tags `[VoiceOS]`, `voiceos.ipc` queue label, notification names | `[Otto]` / `otto.ipc` | |
| repo/top folder `voice-os/` | `otto/` | Physical `mv` done **last**, as a separate explicit step; recreates `.venv` |

**Kept as-is:** Python module filenames (`voice_agent.py`, etc.) — internal and
descriptive; renaming is churn with no brand value. CLAUDE.md updated to match.

## README rewrite

New one-liner + "what Otto is / why it's different" intro centered on the
compounding/learning angle and the native palette UX. Retain the useful
reference material (modes table, how-it-works, capability store, dreaming loop,
config — with `OTTO_` names). Footer credit note:

> Otto began as a fork of [voice-os](https://github.com/per-simmons/voice-os) by
> Pat Simmons (MIT).

## Licensing

`LICENSE` keeps `Copyright (c) 2026 Pat Simmons` and adds
`Copyright (c) 2026 Hamish Burke`. Stays MIT. Plus the README footer credit note.

## Accepted consequences

1. **Bundle-id change resets macOS permissions** — `com.otto.app` is a new app
   to macOS; Accessibility + Mic must be re-granted on first run.
2. **Folder rename breaks `.venv`** — recreated by `run.sh`; done as a final,
   explicit step.

## Out of scope

Historical records under `docs/superpowers/specs|plans/` keep their original
wording (dated artifacts). Detaching the GitHub fork relationship is not part of
this work.

## Verification

- `pytest` (pure suites: retrieval, retrospective, session_log, voice_agent)
- `make app` builds `Otto.app` from the renamed Xcode project
- `grep` sweep: no stray `VOICEOS_` / `VoiceOS` / `voiceos` outside the intended
  back-compat fallbacks and historical docs
