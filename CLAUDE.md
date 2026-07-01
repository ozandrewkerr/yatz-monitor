# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A monitor that watches the **Taronga YATZ** (Youth at the Zoo) volunteer
calendar on **Volgistics VicNet** and messages the user via a **Telegram bot**
when new sign-up openings appear. Single script ([`monitor.sh`](monitor.sh)) in
**bash + curl + jq**, run on a GitHub Actions cron. No build system, no
dependencies.

Chosen as bash (not Python) deliberately: the dev Mac has no working Python
(Xcode CLT not installed) but does have curl + jq, so the whole pipeline is
testable locally and runs identically on the Ubuntu runner.

## Commands

```bash
DRY_RUN=1 ./monitor.sh   # full run, prints intended texts instead of sending
./monitor.sh             # live run (needs Telegram env / .env)
```

There is no test suite. To test logic safely: point `STATE_FILE` at a temp file,
run with `DRY_RUN=1`, and hand-edit that state file to simulate a slot appearing
or disappearing. Secrets come from `.env` (git-ignored, auto-sourced) locally,
or environment variables / GitHub Secrets in CI.

## The VicNet API (reverse-engineered; not publicly documented)

VicNet is an Angular SPA — there is **no scrapeable HTML**; data is JSON from a
private API. The flow `monitor.sh` relies on:

- **Login:** `POST https://www.volgistics.com/api/vicnet/auth/log-in?platform=web`
  with JSON `{"FROM":"201756","email":...,"password":...}`. Returns `{ jwt, ... }`.
  Auth is the **JWT as a bearer token** — there are no cookies.
- **Every request needs** `x-api-key` (a static key baked into the public app
  bundle — the default in `monitor.sh`), `x-client-version: 1.8.0`, a modern
  `User-Agent` (or the site returns an "outdated browser" page), and for authed
  calls `Authorization: Bearer <jwt>`.
- **Calendar:** `GET .../api/vicnet/schedule?date=<ISO>&currView=month&kind=volunteer&...`
  — **one call per month** (`date` = any day in the target month).
  Returns `{ schedule: [ {title,start,end,color,meta}, ... ], ... }`.

### The core data rule (`meta.type`)

Each `schedule[]` entry is `"openings"` (a slot you can sign up for; numeric
`meta.volsNeeded`) or `"scheduled"` (a shift you already hold; `volsNeeded:null`).
**The same `slotNum` can appear as both** when you hold a slot that still has
free spots. The alert rule is therefore:

> new + `type=="openings"` + `volsNeeded>0` + `slotNum` not also `"scheduled"`.

`meta.slotNum` is the stable unique id used for diffing.

## State & the workflow

- [`state.json`](state.json) holds the `slotNum`s open at the last run. It is
  **committed back to the repo** by the workflow (the stateless runner's memory).
  It intentionally has **no timestamp**, so commits happen only on real changes.
- First run (no `state.json`) seeds the baseline and sends nothing.
- [`.github/workflows/monitor.yml`](.github/workflows/monitor.yml): cron `*/5`,
  `permissions: contents: write`, runs the script then commits `state.json` only
  if it changed.

## Gotchas

- Chrome "Copy all as HAR" **redacts** the Authorization header and cookies —
  that's why the bearer token wasn't obvious from the original capture.
- GitHub cron drifts (5–15 min) and pauses after 60 days of repo inactivity.
- `start` times carry the Volgistics server offset (`-04:00`), not Sydney time;
  alerts show that wall-clock time (matches what the website displays).
- If `x-api-key` / `x-client-version` ever stop working, re-capture from the
  app's network traffic and update the defaults in `monitor.sh`.
