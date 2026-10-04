import { createHash, randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, chmodSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";

const [configPath, outputPath] = process.argv.slice(2);
if (!configPath || !outputPath) throw new Error("Usage: provision-agent.ts <iCloud config.json> <private connection.json output>");
const config = JSON.parse(readFileSync(configPath, "utf8"));
if (!/^[a-f0-9-]{36}$/.test(config.workspaceID)) throw new Error("Invalid workspace ID");
const stack = JSON.parse(execFileSync("aws", ["cloudformation", "describe-stacks", "--stack-name", "Workmate", "--region", "eu-north-1", "--output", "json"], { encoding: "utf8" }));
const outputs = Object.fromEntries(stack.Stacks[0].Outputs.map((v: any) => [v.OutputKey, v.OutputValue]));
const id = randomUUID(), token = `wma_${id}.${randomBytes(32).toString("hex")}`;
// Write the recoverable secret first, refusing to replace an existing key file.
writeFileSync(outputPath, JSON.stringify({ apiURL: outputs.ApiUrl, token }, null, 2) + "\n", { mode: 0o600, flag: "wx" });
chmodSync(outputPath, 0o600);
const client = DynamoDBDocumentClient.from(new DynamoDBClient({ region: "eu-north-1" }));
await client.send(new PutCommand({ TableName: outputs.TableName, Item: { pk: "AGENT#" + id, value: {
  user: "drive-" + config.workspaceID, enabled: true, tokenHash: createHash("sha256").update(token).digest("hex"),
}}, ConditionExpression: "attribute_not_exists(pk)" }));
console.log("Created a reminder-only Pi connection. Install its file with mode 600; keep it outside Git.");
