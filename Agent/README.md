# Raspberry Pi reminder agent

A separate outbound-only Docker service, following the existing support-bot setup: restart unless stopped, persistent data, a private configuration file outside Git, bounded logs and no published ports. Requires Docker Compose on an ARM64 or x86-64 Linux host.

The Pi maintains one outbound TLS MQTT connection to AWS IoT Core in eu-north-1. DynamoDB Streams publishes a small change event when reminder timing, recurrence, completion or delivery settings change. The Pi fetches the latest plan on that event, on reconnect, or after a timer finishes to replenish recurring occurrences. There is **no periodic plan polling**. It stores timers in SQLite and sleeps until the next due time or incoming event. Failed requests retry with backoff. MQTT keep-alives maintain the connection; local Docker health checks do not call AWS. The API rechecks each due job against the latest workspace and owns shared delivery receipts, so AWS fallback task/daily schedules and the Pi do not normally send duplicates. A crash after Telegram accepts a message but before its receipt is stored can still cause a retry; Telegram has no send-message idempotency key.

Task reminders respect **Also notify in Telegram**. Enabled meeting reminders and the daily brief are included. Recurring meetings support multiple weekdays with different times, overnight meetings and timezone/DST changes. Task reminders catch up for up to 24 hours, daily briefs for six hours, meeting reminders until five minutes after the start (or the meeting end, whichever is earlier).

The agent has no Telegram bot token or access to note text. A dedicated IoT certificate can connect as only this agent and subscribe/receive on only this workspace’s change topic; it cannot publish, use wildcards, or access other workspaces. Its dedicated key can only fetch job IDs/times and ask the API to deliver an eligible notification for one workspace. The key cannot read or write the workspace, connect a bot, or change a meeting.

## Install

Deploy the AWS stack first. From a backend development copy with dependencies installed:

```sh
npx tsx scripts/provision-agent.ts '/path/to/iCloud/Documents/Workmate/config.json' '/private/path/connection.json'
npx tsx scripts/provision-push.ts '/path/to/iCloud/Documents/Workmate/config.json' '/private/path/connection.json' '/private/path/credentials'
```

This generates a separate key. It never copies the full workspace connection key to the Pi. Copy the resulting file to `Agent/connection.json` and the certificate directory to `Agent/credentials` on the Pi. Use mode 600 for files and 700 for the directory. The file must be owned by UID 1000, matching the container user. Existing connections must be preserved during updates.

```sh
cd /path/to/workmate/Agent
mkdir -p data
chmod 700 data
chmod 600 connection.json credentials/*
chmod 700 credentials
docker compose up -d --build
docker compose ps
docker compose logs --tail 30
```

No credentials belong in shell arguments, the image, Git or the app bundle. Revoke a Pi key by setting `enabled: false` on its `AGENT#<key-id>` DynamoDB record, and set the IoT certificate to INACTIVE. The certificate identity is recorded in `credentials/identity.json`. Stop the container during revocation. Replace the connection and certificate files together when rotating credentials. To upgrade an existing polling installation, run only `provision-push.ts` against its existing agent connection, then rebuild the container. Keep the old delivery database.

## Update and check

```sh
cd /path/to/workmate
git pull --ff-only
cd Agent
docker compose up -d --build
docker compose ps
python3 -m unittest discover -s tests -v
```

`docker compose stop` pauses the agent without deleting its queue. Keep `Agent/data` across rebuilds. Docker health requires a live push subscription, a successfully loaded plan, and a responsive timer loop. Logs report push connection events, schedule refreshes, delivery status and error type without note contents or credentials. Settings in Workmate shows when the Pi last synchronized its schedule, not a guessed online status. An idle connected agent may legitimately make no plan API requests for hours. Reconnect always fetches current state, including changes missed while offline; every delivery is revalidated by the API even if a push was delayed.

## Delivery boundaries

The Pi and AWS require internet access. New edits reach the Pi after the Mac app syncs them to AWS. macOS independently delivers already-scheduled native notifications even when Workmate is closed; the Pi is responsible for Telegram and does not bypass Apple's notification system or wake a powered-off Mac. Telegram completion/snooze changes are stored in AWS/S3 immediately and merged into iCloud when Workmate runs again. Calendar imports refresh while Workmate is running.

Tests use fake transports and temporary databases; they do not send Telegram messages.
