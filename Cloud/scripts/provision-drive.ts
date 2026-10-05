import { createHash, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
} from "@aws-sdk/lib-dynamodb";

const configPath = process.argv[2];
if (!configPath)
  throw new Error("Pass the path to Workmate's config.json in iCloud Drive.");
const config = JSON.parse(readFileSync(configPath, "utf8"));
if (!/^[a-f0-9-]{36}$/.test(config.workspaceID))
  throw new Error("Invalid workspace ID");
const region = process.env.AWS_REGION || "eu-north-1";
const stack = JSON.parse(
  execFileSync(
    "aws",
    [
      "cloudformation",
      "describe-stacks",
      "--stack-name",
      "Workmate",
      "--region",
      region,
      "--output",
      "json",
    ],
    { encoding: "utf8" },
  ),
);
const outputs = Object.fromEntries(
  stack.Stacks[0].Outputs.map((v: any) => [v.OutputKey, v.OutputValue]),
);
if (config.serviceToken && config.apiURL && config.apiURL !== outputs.ApiUrl) {
  throw new Error(
    "This workspace is already connected to another deployment. Back up config.json and disconnect that deployment before switching accounts.",
  );
}
const client = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const key = "DEVICE#" + config.workspaceID;
const current = (
  await client.send(
    new GetCommand({
      TableName: outputs.TableName,
      Key: { pk: key },
      ConsistentRead: true,
    }),
  )
).Item;
if (current) {
  const hash = createHash("sha256")
    .update(config.serviceToken || "")
    .digest("hex");
  if (current.value.tokenHash !== hash || !current.value.enabled)
    throw new Error(
      "A different connection already exists. Recover its config instead of silently replacing its key.",
    );
} else {
  config.serviceToken = `wm_${config.workspaceID}.${randomBytes(32).toString("hex")}`;
  await client.send(
    new PutCommand({
      TableName: outputs.TableName,
      Item: {
        pk: key,
        value: {
          user: "drive-" + config.workspaceID,
          enabled: true,
          tokenHash: createHash("sha256")
            .update(config.serviceToken)
            .digest("hex"),
        },
      },
      ConditionExpression: "attribute_not_exists(pk)",
    }),
  );
}
config.apiURL = outputs.ApiUrl;
config.backupEnabled = true;
const temporary = configPath + ".provisioning";
writeFileSync(temporary, JSON.stringify(config, null, 2) + "\n", {
  mode: 0o600,
});
chmodSync(temporary, 0o600);
renameSync(temporary, configPath);
console.log(
  "Private AWS backup connection saved to the Workmate folder. No user account or invitation required.",
);
