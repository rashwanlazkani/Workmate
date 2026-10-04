# Optional Workmate cloud backend

The macOS app is native Swift and runs without Node. This folder contains the TypeScript source for its AWS backend: a private workspace-key API, S3 backups, DynamoDB storage, EventBridge Scheduler reminders, and Telegram delivery. The native app saves its main files in iCloud Drive and does not use a Workmate sign-in. Application services and data use **eu-north-1 (Stockholm)**.

## Develop and deploy

Requires Node 20 or later, AWS CLI credentials, and access to the existing Workmate account:

```sh
cd Cloud
npm ci
npm run check
AWS_PROFILE=default npm run deploy
```

`check` type-checks the backend, runs unit tests, and synthesizes CloudFormation. Deployment bootstraps CDK when necessary, deploys the Workmate stack, and updates `../Resources/CloudConfig.json`. Rebuild the native app afterwards with `zsh Scripts/build.sh` from the project root. The deployment script does not publish a website.

After the native app creates its iCloud folder, provision its private connection with your existing AWS administrator session:

```sh
npm run provision:drive -- "/path/to/iCloud Drive/Documents/Workmate/config.json"
```

This saves a random 256-bit workspace key only into the user's private config file and its SHA-256 hash into DynamoDB. It never emails an invitation or includes a key in the app bundle. Existing connections are checked instead of silently rotated. The `/device` route authenticates the key and binds it to one workspace before serving any data. Revocation: set the matching `DEVICE#<workspaceID>` record's `value.enabled` to false.

`npm run test:drive` provisions an isolated temporary workspace, tests the real Swift client and S3 backup, then deletes its test data. It sends no email or Telegram messages. The older Cognito test and invitation scripts remain for compatibility with existing deployments; they are not needed by the current app.

Dependencies and synthesis output are generated only for backend development. You can remove `node_modules/` and `cdk.out/` after use; `package-lock.json` preserves reproducible installation.

## Existing stack compatibility

The deployed stack still contains S3 and CloudFront resources from the previous website. Their definitions and existing logical IDs are retained to avoid unintended cloud resource deletion during local project cleanup. The old web client and web publishing scripts have been removed. No AWS resources were deleted by that cleanup.

## Data and reminders

For current app data, a `drive-<workspaceID>` identity scopes ownership. S3 snapshots are immutable objects under that workspace prefix; they are written before a workspace update is acknowledged. The private backup bucket is separate from the old website bucket, uses encryption and versioning, and blocks public access. Old Cognito identities remain supported for migration compatibility. DynamoDB manifests use optimistic revisions; workspace content is split into immutable chunks below the item size limit. Changed reminders flow through DynamoDB Streams to a planner Lambda, then EventBridge Scheduler and a delivery Lambda. Workers re-read current state to ignore stale reminders. Completing or deleting tasks removes their schedules.

Bot tokens live in Secrets Manager and are excluded from workspace backups. Delivery leases reduce duplicate retries, although Telegram has no send-message idempotency key. Failures feed an SQS queue and CloudWatch alarm. DynamoDB point-in-time recovery is enabled; logs retain fourteen days. The table, user pool, and legacy website bucket are retained on stack deletion.

## Raspberry Pi runner

`/agent/plan` and `/agent/deliver` require a separate, provisioned agent key. The plan exposes only timing and opaque identifiers for opted-in task reminders, enabled meetings and the daily brief. The API validates a delivery against the newest workspace before sending and shares receipts with EventBridge fallback schedules. It supports per-weekday meeting times and timezone transitions. The agent heartbeat is available in the existing Telegram status response.

Telegram callbacks validate the paired chat, persist completion or a one-hour snooze, back up the change to S3, and edit the original message with confirmation. Completed tasks remain in Archive. The Mac merges these edits into iCloud at its next sync. See `../Agent/README.md` for provisioning, Docker deployment, verification and revocation.
