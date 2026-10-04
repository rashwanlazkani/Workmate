import { createHash } from "node:crypto";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import type { Workspace } from "../src/model";
const s3 = new S3Client({});
export async function backupWorkspace(user: string, workspace: Workspace) {
  const body = JSON.stringify(workspace);
  const digest = createHash("sha256").update(body).digest("hex");
  await s3.send(new PutObjectCommand({
    Bucket: process.env.BACKUP_BUCKET,
    Key: `workspaces/${user.slice(6)}/snapshots/${String(workspace.revision + 1).padStart(12, "0")}-${digest}.json`,
    Body: body, ContentType: "application/json", ServerSideEncryption: "AES256",
  }));
}
