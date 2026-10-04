import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, ListObjectsV2Command, GetObjectCommand, ListObjectVersionsCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";

const region = "eu-north-1";
const stack = JSON.parse(execFileSync("aws", ["cloudformation", "describe-stacks", "--stack-name", "Workmate", "--region", region, "--output", "json"], { encoding: "utf8" }));
const outputs = Object.fromEntries(stack.Stacks[0].Outputs.map((v: any) => [v.OutputKey, v.OutputValue]));
const directory = mkdtempSync(path.join(tmpdir(), "workmate-drive-test-"));
const file = path.join(directory, "config.json");
const id = randomUUID();
const prefix = `workspaces/${id}/`;
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const s3 = new S3Client({ region });
writeFileSync(file, JSON.stringify({ version: 1, workspaceID: id, apiURL: outputs.ApiUrl, backupEnabled: true, columns: [], selectedCalendars: [], intelligenceEnabled: false }), { mode: 0o600 });
try {
  execFileSync("npx", ["tsx", "scripts/provision-drive.ts", file], { stdio: "inherit" });
  const unauth = await fetch(outputs.ApiUrl + "/device/workspace");
  if (unauth.status !== 401) throw new Error("Unauthenticated access was not rejected");
  execFileSync("zsh", ["Scripts/test.sh", "--filter", "DriveCloudTests"], {
    cwd: process.env.WORKMATE_PROJECT_ROOT || path.resolve(".."), stdio: "inherit",
    env: { ...process.env, WORKMATE_DRIVE_TEST_FILE: file },
  });
  const objects = await s3.send(new ListObjectsV2Command({ Bucket: outputs.BackupBucketName, Prefix: prefix }));
  if (!objects.Contents?.length) throw new Error("Missing S3 snapshot");
  const snapshot = await s3.send(new GetObjectCommand({ Bucket: outputs.BackupBucketName, Key: [...objects.Contents].sort((a, b) => b.Key!.localeCompare(a.Key!))[0].Key }));
  const workspace = JSON.parse(await snapshot.Body!.transformToString());
  if (workspace.notes[0]?.title !== "iCloud backup check" || snapshot.ServerSideEncryption !== "AES256") throw new Error("S3 backup validation failed");
  console.log("Verified native private-key access, conflict rejection, Telegram status, and encrypted S3 snapshot. No email or Telegram messages sent.");
} finally {
  rmSync(directory, { recursive: true, force: true });
  let cursor: Record<string, any> | undefined;
  do {
    const page = await ddb.send(new ScanCommand({ TableName: outputs.TableName, ProjectionExpression: "pk", ExclusiveStartKey: cursor }));
    for (const item of page.Items || []) {
      if (item.pk === "DEVICE#" + id || item.pk === "WORKSPACE#drive-" + id || item.pk.startsWith("CHUNK#WORKSPACE#drive-" + id + "#")) {
        await ddb.send(new DeleteCommand({ TableName: outputs.TableName, Key: { pk: item.pk } }));
      }
    }
    cursor = page.LastEvaluatedKey;
  } while (cursor);
  const versions = await s3.send(new ListObjectVersionsCommand({ Bucket: outputs.BackupBucketName, Prefix: prefix }));
  for (const version of [...versions.Versions || [], ...versions.DeleteMarkers || []]) {
    await s3.send(new DeleteObjectCommand({ Bucket: outputs.BackupBucketName, Key: version.Key, VersionId: version.VersionId }));
  }
  console.log("Isolated test connection and backup objects removed.");
}
