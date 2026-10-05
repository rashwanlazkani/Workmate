# Security

Report vulnerabilities privately using GitHub’s **Security → Report a vulnerability** for this repository. Do not open public issues containing credentials, workspace JSON, Telegram tokens, or personal notes. Include reproduction steps using synthetic data. This is a community project without a guaranteed response SLA.

## Boundaries

- Local notes work without any backend. iCloud sync is handled by Apple.
- AWS is opt-in and self-hosted in your account. You control permissions, billing, backups and updates.
- The private `config.json` contains a workspace-scoped bearer key. Treat it as a password; it is portable through iCloud. AWS administrator credentials never belong there.
- AI provider keys use macOS Keychain. Selected text or displayed search passages are sent only when cloud AI is explicitly invoked. The local allowance is not an account-wide provider billing guarantee.
- Telegram bot tokens live in your AWS Secrets Manager. Use a dedicated bot.

If a key leaks, revoke/rotate it at its owner service immediately; deleting it from the latest commit is insufficient. For a workspace key, disable its `DEVICE#<workspaceID>` record in DynamoDB before reprovisioning. See the cloud setup guide for removal and retained resources.

Source builds are not notarized releases. Review code and use your own signing identity when appropriate. Secret scanning reduces risk but cannot prove that a repository contains no sensitive data.
