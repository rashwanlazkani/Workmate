# Optional AWS backend — bring your own account

Workmate is fully usable without this folder. AWS is disabled for new workspaces. Enable it only if you want S3 backups and Telegram reminders while the Mac app is closed. **There is no shared Workmate service: deploy in your own AWS account and pay your own AWS charges.** The app’s AI monthly allowance does not limit AWS costs.

## 1. Prepare your AWS account

Install Node.js 22+, npm, AWS CLI v2, and configure a named AWS CLI profile using your own account (for example `aws configure sso --profile workmate`). Sign in if required, then verify the account:

```sh
aws sso login --profile workmate
aws sts get-caller-identity --profile workmate
```

Deployment needs CloudFormation/CDK provisioning permissions for IAM, Lambda, API Gateway, DynamoDB, S3, EventBridge Scheduler, Secrets Manager, SQS and CloudWatch. Administrator access in a dedicated personal AWS account is one setup option; do not put access keys in the app, source files, issues or screenshots. Configure an AWS Budget separately; billing alerts are not a hard spending cap.

## 2. Deploy

From the repository:

```sh
cd Cloud
npm ci
npm run check
AWS_PROFILE=workmate AWS_REGION=eu-north-1 npm run deploy
```

Use your chosen AWS region consistently when deploying and provisioning. The script displays the target account, bootstraps CDK if needed, and asks for approval of security permission changes. Review the deployment before approving. `cdk-outputs.json` stays local and ignored by Git. No endpoint or credentials are written into the application bundle or tracked source.

New deployments create a private, encrypted, versioned S3 backup bucket; DynamoDB with point-in-time recovery; API/worker/planner Lambdas; an HTTP API; EventBridge schedules; Secrets Manager storage; a failure queue and alarm. No EC2 instance, Raspberry Pi, website, Cognito login or always-running container is needed.

## 3. Connect your private workspace

Open the native app once. In **Settings → AWS backup → Show configuration folder**, locate its `config.json` (usually iCloud Drive → Documents → Workmate). Then run:

```sh
AWS_PROFILE=workmate AWS_REGION=eu-north-1 npm run provision:drive -- "/absolute/path/to/Workmate/config.json"
```

This creates a random 256-bit workspace access key in that private file and stores only its SHA-256 hash in your DynamoDB table. It enables backup explicitly. The running app reloads the configuration; no rebuild or Workmate account is needed. Existing keys are validated, never silently rotated. Switching an already connected workspace to a different deployment is refused to prevent accidental data upload to another account.

Keep `config.json` private: it grants access to this workspace’s AWS copy. It syncs through your iCloud Drive for use on your other Macs. AWS CLI administrator credentials are never saved there. Do not provision someone else’s workspace against your account unless you intend to host their data and pay their charges.

## 4. Optional Telegram

After AWS is connected, open **Settings → Telegram**. Create your own bot through BotFather, paste its bot token, and open the pairing link. Bot tokens are stored in your AWS Secrets Manager and excluded from workspace backups. Enable Telegram individually for tasks; local Mac notifications do not require AWS. A bot supports one webhook deployment at a time.

DynamoDB changes update EventBridge Scheduler directly. Workers re-read current state to discard stale reminders. Telegram supports completion and one-hour snooze; these edits sync to the Mac when it next connects. There is no external agent. Weekly meetings use their timezone; nonexistent local times during the spring DST transition are skipped by AWS Scheduler.

## Updates and existing installations

Run the same deploy command with the same profile and region. The deployment script detects older stacks with website/Cognito resources and preserves their logical IDs automatically. For a manual `cdk diff` or `cdk deploy` on an older installation, pass `--context legacyWeb=true`; omitting it can remove legacy infrastructure. Fresh installations omit these resources. Each account/region supports one default `Workmate` stack.

The current native API uses a workspace-scoped key and has no public registration endpoint. Legacy Cognito scripts remain only for existing installations. `npm run test:drive` is an opt-in integration test against your deployed account: it creates a temporary workspace, exercises the Swift client and backups, then cleans up. It does not send Telegram messages. Unit tests and synthesis require no live deployment.

## Disable or remove

Switch off **Keep an AWS backup** to stop app uploads and downloads. Already scheduled reminders remain active. To stop Telegram delivery, disconnect Telegram before disabling backup. To revoke a workspace key, set its DynamoDB `DEVICE#<workspaceID>` record’s `value.enabled` to `false`, remove its credentials from the private config, and delete its schedules in the `workmate-reminders` schedule group.

For complete teardown, remove schedules in that group, review `cdk destroy`, and inspect retained resources. The workspace table and backup bucket intentionally remain to prevent accidental data loss; delete them separately only after exporting anything you want to keep. Retained storage, secrets, logs and CDK bootstrap assets can continue to incur charges. Never run teardown in someone else’s account.

## Data handling

Workspace identity is `drive-<workspaceID>`. Private immutable S3 snapshots are written before updates are acknowledged. DynamoDB uses optimistic revisions and immutable chunks for large notes. iCloud/local files remain the primary workspace. Failed uploads leave local edits intact. Delivery receipts reduce duplicate sends; Telegram provides no send-message idempotency key, so exactly-once delivery is not guaranteed. Logs retain fourteen days; inspect the failure queue and alarm when delivery fails.
