import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
  AdminDeleteUserCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  ScanCommand,
  BatchWriteCommand,
} from "@aws-sdk/lib-dynamodb";
import { randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
const o = JSON.parse(readFileSync("cdk-outputs.json", "utf8")).Workmate;
const region = "eu-north-1";
const cognito = new CognitoIdentityProviderClient({ region });
const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const email = `workmate-native-test-${randomUUID()}@example.invalid`;
const password = "Wm!" + randomBytes(24).toString("base64url") + "9a";
const fixtureDirectory = mkdtempSync(resolve(tmpdir(), "workmate-cloud-test-"));
const fixture = resolve(fixtureDirectory, "credentials.json");
let sub = "";
try {
  const created = await cognito.send(
    new AdminCreateUserCommand({
      UserPoolId: o.UserPoolId,
      Username: email,
      MessageAction: "SUPPRESS",
      UserAttributes: [
        { Name: "email", Value: email },
        { Name: "email_verified", Value: "true" },
      ],
    }),
  );
  sub = created.User!.Attributes!.find((a) => a.Name === "sub")!.Value!;
  await cognito.send(
    new AdminSetUserPasswordCommand({
      UserPoolId: o.UserPoolId,
      Username: email,
      Password: password,
      Permanent: true,
    }),
  );
  writeFileSync(
    fixture,
    JSON.stringify({
      region,
      clientId: o.ClientId,
      apiUrl: o.ApiUrl,
      email,
      password,
    }),
    { mode: 0o600 },
  );
  const result = spawnSync(
    "zsh",
    [
      resolve("../Scripts/test.sh"),
      "--filter",
      "CloudTests",
    ],
    {
      cwd: resolve(".."),
      stdio: "inherit",
      env: { ...process.env, WORKMATE_CLOUD_TEST_FILE: fixture },
    },
  );
  if (result.status !== 0) throw new Error("Native cloud check failed");
} finally {
  try {
    rmSync(fixtureDirectory, { recursive: true, force: true });
  } catch {}
  if (sub) {
    let cursor: Record<string, any> | undefined;
    do {
      const rows = await dynamo.send(
        new ScanCommand({
          TableName: o.TableName,
          FilterExpression: "begins_with(pk, :prefix) OR pk = :head",
          ExpressionAttributeValues: {
            ":prefix": `CHUNK#WORKSPACE#${sub}#`,
            ":head": `WORKSPACE#${sub}`,
          },
          ProjectionExpression: "pk",
          ExclusiveStartKey: cursor,
        }),
      );
      for (let i = 0; i < (rows.Items || []).length; i += 25) {
        let pending = rows
          .Items!.slice(i, i + 25)
          .map((row) => ({ DeleteRequest: { Key: row } }));
        for (let attempt = 0; pending.length && attempt < 5; attempt++) {
          const result = await dynamo.send(
            new BatchWriteCommand({ RequestItems: { [o.TableName]: pending } }),
          );
          pending = (result.UnprocessedItems?.[o.TableName] ||
            []) as typeof pending;
        }
        if (pending.length)
          throw new Error("Could not remove native test data");
      }
      cursor = rows.LastEvaluatedKey;
    } while (cursor);
    await cognito.send(
      new AdminDeleteUserCommand({ UserPoolId: o.UserPoolId, Username: email }),
    );
    console.log("Temporary native test account and workspace removed.");
  }
}
