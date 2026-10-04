import assert from "node:assert/strict";
import { randomUUID, randomBytes, createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, DeleteCommand } from "@aws-sdk/lib-dynamodb";
import { DynamoRepository } from "../server/repository";
import { emptyWorkspace, workspaceSchema } from "../src/model";

const region = "eu-north-1";
const stack = JSON.parse(execFileSync("aws", ["cloudformation", "describe-stacks", "--stack-name", "Workmate", "--region", region, "--output", "json"], { encoding: "utf8" }));
const outputs = Object.fromEntries(stack.Stacks[0].Outputs.map((v: any) => [v.OutputKey, v.OutputValue]));
process.env.AWS_REGION = region; process.env.TABLE_NAME = outputs.TableName;
const id = randomUUID(), user = "drive-" + id, agentID = randomUUID(), token = `wma_${agentID}.${randomBytes(32).toString("hex")}`;
const repo = new DynamoRepository();
const now = Date.now();
async function request(path: string, method = "GET", body?: unknown, auth = token) {
  return fetch(outputs.ApiUrl + "/agent" + path, { method, headers: { Authorization: "Bearer " + auth, "Content-Type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
}
try {
  const meeting = { id: randomUUID(), title: "Isolated notification check", startAt: new Date(now + 5 * 60000).toISOString(), endAt: new Date(now + 35 * 60000).toISOString(), timezone: "Europe/Stockholm", recurrence: "none", reminderMinutes: 10, reminderEnabled: true, canceled: false, calendarEventId: "", calendarId: "", calendarName: "", location: "" };
  const workspace = workspaceSchema.parse({ ...emptyWorkspace(), meetings: [meeting] });
  await repo.put("WORKSPACE#" + user, workspace);
  await repo.put("AGENT#" + agentID, { user, enabled: true, tokenHash: createHash("sha256").update(token).digest("hex") });
  assert.equal((await request("/plan", "GET", undefined, token + "bad")).status, 401);
  assert.equal((await request("/workspace")).status, 404);
  assert.equal((await request("/telegram/connect", "POST", { token: "unused" })).status, 404);
  const response = await request("/plan"); assert.equal(response.status, 200);
  const plan = await response.json() as any;
  assert.equal(plan.jobs.length, 1); assert.equal(plan.jobs[0].kind, "meeting");
  assert.equal(JSON.stringify(plan).includes(meeting.title), false);
  const delivered = await request("/deliver", "POST", { id: plan.jobs[0].id });
  assert.equal(delivered.status, 200);
  assert.equal((await delivered.json() as any).status, "skipped"); // No bot bound: no message can be sent.
  workspace.meetings![0].canceled = true; workspace.revision++;
  await repo.put("WORKSPACE#" + user, workspace);
  const canceled = await request("/deliver", "POST", { id: plan.jobs[0].id });
  assert.equal((await canceled.json() as any).status, "canceled");
  assert.ok(await repo.get("AGENT_STATUS#" + user));
  console.log("Live agent API: scoped auth, private plan, due-job validation, cancellation and heartbeat verified. No Mac client or Telegram messages involved.");
} finally {
  const db = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
  let cursor: Record<string, any> | undefined;
  do {
    const page = await db.send(new ScanCommand({ TableName: outputs.TableName, ProjectionExpression: "pk", ExclusiveStartKey: cursor }));
    for (const row of page.Items ?? []) {
      if (["WORKSPACE#" + user, "AGENT#" + agentID, "AGENT_STATUS#" + user].includes(row.pk) || row.pk.startsWith("CHUNK#WORKSPACE#" + user + "#"))
        await db.send(new DeleteCommand({ TableName: outputs.TableName, Key: { pk: row.pk } }));
    }
    cursor = page.LastEvaluatedKey;
  } while (cursor);
  console.log("Removed isolated agent test records.");
}
