# YATZ openings monitor

Watches the **Taronga YATZ** (Youth at the Zoo) volunteer calendar on
[Volgistics VicNet](https://www.volgistics.com/vicnet/201756) and **messages you
on Telegram when a new sign-up opening appears**, so you don't have to keep
refreshing the site.

## How it works

VicNet is a JavaScript app whose calendar comes from a private JSON API. Each
run, [`monitor.sh`](monitor.sh):

1. Logs in with your email + password and gets a short-lived session token.
2. Fetches the calendar for the current month + the next few months.
3. Keeps only **openings** you can sign up for — it ignores shifts you're
   already booked on, and even hides openings on a slot you already hold.
4. Compares against [`state.json`](state.json) (what was open last run) and, for
   anything **new**, sends you a Telegram message.
5. Saves the current openings back to `state.json`.

The **first** run just records a baseline silently (no flood of texts); from
then on you only hear about genuinely new openings.

Only `bash`, `curl`, and `jq` are needed — no build step, no dependencies.

## Run it locally

```bash
cp .env.example .env     # then edit .env with your details
DRY_RUN=1 ./monitor.sh   # prints what it WOULD send, sends nothing
./monitor.sh             # sends real Telegram messages
```

`DRY_RUN=1` is the safe way to try it. Delete `state.json` to reset the baseline.

## Set up the Telegram bot (free)

1. In Telegram, message **@BotFather** → send `/newbot`, give it a name, and copy
   the **bot token** it returns → `TELEGRAM_BOT_TOKEN`.
2. Open a chat with your new bot and send it any message (e.g. "hi") so it's
   allowed to message you back.
3. Get your **chat ID**: message **@userinfobot**, which replies with your numeric
   ID → `TELEGRAM_CHAT_ID`.

## Deploy on GitHub Actions (runs 24/7, free)

1. **Create a private GitHub repo** and push this folder to it.
2. In the repo: **Settings → Secrets and variables → Actions → New repository
   secret**, and add:
   | Secret | Value |
   |---|---|
   | `YATZ_EMAIL` | your VicNet login email |
   | `YATZ_PASSWORD` | your VicNet password |
   | `TELEGRAM_BOT_TOKEN` | from @BotFather |
   | `TELEGRAM_CHAT_ID` | from @userinfobot |
3. Go to the **Actions** tab, enable workflows, and run **YATZ openings
   monitor → Run workflow** once to seed the baseline. After that the cron runs
   it every ~5 minutes automatically.

## Good to know

- **Timing:** GitHub's cron is best-effort — "every 5 min" is often 5–15 min.
- **Schedules pause after 60 days** of repo inactivity; the committed
  `state.json` updates keep the repo active. Push or re-enable if it ever stops.
- **Times** shown in alerts use Volgistics' server timezone (the same wall-clock
  time the website displays); double-check against the calendar.
- This automates access to **your own** volunteer account only.

See [CLAUDE.md](CLAUDE.md) for the API/architecture details.
