# Raspberry Pi reminder agent

A separate outbound-only Docker service, following the existing support-bot setup: restart unless stopped, persistent data, a private configuration file outside Git, bounded logs and no published ports. Requires Docker Compose on an ARM64 or x86-64 Linux host.

The Pi polls the AWS notification plan every 15 seconds. It stores job state in SQLite, retries failures with backoff and reconciles cancellations before sending. The API rechecks each due job against the latest workspace and owns shared delivery receipts, so AWS fallback task/daily schedules and the Pi do not normally send duplicates. A crash after Telegram accepts a message but before its receipt is stored can still cause a retry; Telegram has no send-message idempotency key.

Task reminders respect **Also notify in Telegram**. Enabled meeting reminders and the daily brief are included. Recurring meetings support multiple weekdays with different times, overnight meetings and timezone/DST changes. Task reminders catch up for up to 24 hours, daily briefs for six hours, meeting reminders until five minutes after the start (or the meeting end, whichever is earlier).

The agent has no Telegram bot token or access to note text. Its dedicated key can only fetch job IDs/times and ask the API to deliver an eligible notification for one workspace. The key cannot read or write the workspace, connect a bot, or change a meeting.

## Install

Deploy the AWS stack first. From a backend development copy with dependencies installed:

```sh
npx tsx scripts/provision-agent.ts '/path/to/iCloud/Documents/Workmate/config.json' '/private/path/connection.json'
```

This generates a separate key. It never copies the full workspace connection key to the Pi. Copy the resulting file to `Agent/connection.json` on the Pi with mode 600. The file must be owned by UID 1000, matching the container user. Existing connections must be preserved during updates.

```sh
cd /path/to/workmate/Agent
mkdir -p data
chmod 700 data
chmod 600 connection.json
docker compose up -d --build
docker compose ps
docker compose logs --tail 30
```

No credentials belong in shell arguments, the image, Git or the app bundle. Revoke a Pi key by setting `enabled: false` on its `AGENT#<key-id>` DynamoDB record. Replace the connection file to rotate it.

## Update and check

```sh
cd /path/to/workmate
git pull --ff-only
cd Agent
docker compose up -d --build
docker compose ps
python3 -m unittest discover -s tests -v
```

`docker compose stop` pauses the agent without deleting its queue. Keep `Agent/data` across rebuilds. Docker marks the container unhealthy if it cannot refresh the plan for three minutes. Logs report status and error type without note contents or credentials. Settings in Workmate shows the last agent heartbeat.

## Delivery boundaries

The Pi and AWS require internet access. New edits reach the Pi after the Mac app syncs them to AWS. macOS independently delivers already-scheduled native notifications even when Workmate is closed; the Pi is responsible for Telegram and does not bypass Apple's notification system or wake a powered-off Mac. Telegram completion/snooze changes are stored in AWS/S3 immediately and merged into iCloud when Workmate runs again. Calendar imports refresh while Workmate is running.

Tests use fake transports and temporary databases; they do not send Telegram messages.
