import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, existsSync, renameSync } from "node:fs";
import { resolve, join } from "node:path";
import { execFileSync } from "node:child_process";
import { IoTClient, DescribeEndpointCommand, CreateKeysAndCertificateCommand, CreatePolicyCommand, AttachPolicyCommand } from "@aws-sdk/client-iot";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, GetCommand } from "@aws-sdk/lib-dynamodb";
import { changeTopic } from "../server/push";

const [workspacePath, connectionPath, directory] = process.argv.slice(2);
if (!workspacePath || !connectionPath || !directory) throw new Error("Usage: provision-push.ts <workspace config.json> <Pi connection.json> <private certificate directory>");
const workspace = JSON.parse(readFileSync(workspacePath, "utf8"));
const connection = JSON.parse(readFileSync(connectionPath, "utf8"));
if (connection.mqtt || existsSync(directory)) throw new Error("Refusing to replace an existing push connection or certificate directory");
const match = /^wma_([a-f0-9-]{36})\.[a-f0-9]{64}$/.exec(connection.token);
if (!match || !/^[a-f0-9-]{36}$/.test(workspace.workspaceID)) throw new Error("Invalid workspace or agent configuration");
const region = "eu-north-1";
const stack = JSON.parse(execFileSync("aws", ["cloudformation", "describe-stacks", "--stack-name", "Workmate", "--region", region, "--output", "json"], { encoding: "utf8" }));
const outputs = Object.fromEntries(stack.Stacks[0].Outputs.map((v: any) => [v.OutputKey, v.OutputValue]));
const account = stack.Stacks[0].StackId.split(":")[4];
const user = "drive-" + workspace.workspaceID;
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region }));
const record = await ddb.send(new GetCommand({ TableName: outputs.TableName, Key: { pk: "AGENT#" + match[1] }, ConsistentRead: true }));
if (record.Item?.value?.user !== user || !record.Item.value.enabled || record.Item.value.tokenHash !== createHash("sha256").update(connection.token).digest("hex")) throw new Error("Agent key does not belong to this workspace");
const clientID = "workmate-" + match[1], topic = changeTopic(user), policyName = clientID;
const iot = new IoTClient({ region });
const endpoint = await iot.send(new DescribeEndpointCommand({ endpointType: "iot:Data-ATS" }));
const certificate = await iot.send(new CreateKeysAndCertificateCommand({ setAsActive: true }));
// Save immediately for recovery if a later policy operation fails. Never print private material.
mkdirSync(directory, { mode: 0o700 });
writeFileSync(join(directory, "device.crt"), certificate.certificatePem!, { mode: 0o600, flag: "wx" });
writeFileSync(join(directory, "device.key"), certificate.keyPair!.PrivateKey!, { mode: 0o600, flag: "wx" });
writeFileSync(join(directory, "identity.json"), JSON.stringify({ certificateArn: certificate.certificateArn, certificateId: certificate.certificateId, policyName, clientID, topic }, null, 2), { mode: 0o600, flag: "wx" });
const arn = `arn:aws:iot:${region}:${account}`;
await iot.send(new CreatePolicyCommand({ policyName, policyDocument: JSON.stringify({ Version: "2012-10-17", Statement: [
  { Effect: "Allow", Action: "iot:Connect", Resource: `${arn}:client/${clientID}` },
  { Effect: "Allow", Action: "iot:Subscribe", Resource: `${arn}:topicfilter/${topic}` },
  { Effect: "Allow", Action: "iot:Receive", Resource: `${arn}:topic/${topic}` },
] }) }));
await iot.send(new AttachPolicyCommand({ policyName, target: certificate.certificateArn! }));
connection.mqtt = { endpoint: endpoint.endpointAddress, clientID, topic,
  certificateFile: "/run/secrets/mqtt/device.crt", privateKeyFile: "/run/secrets/mqtt/device.key" };
const temporary = resolve(connectionPath) + ".push-new";
writeFileSync(temporary, JSON.stringify(connection, null, 2) + "\n", { mode: 0o600, flag: "wx" });
renameSync(temporary, connectionPath);
console.log("Provisioned a receive-only push certificate for this workspace. Private files saved; no credentials printed.");
