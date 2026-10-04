import { randomUUID } from "node:crypto";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import {
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  DeleteCommand,
  BatchGetCommand,
  BatchWriteCommand,
  UpdateCommand,
} from "@aws-sdk/lib-dynamodb";
import {
  SecretsManagerClient,
  GetSecretValueCommand,
  CreateSecretCommand,
  PutSecretValueCommand,
  DeleteSecretCommand,
} from "@aws-sdk/client-secrets-manager";
export class Conflict extends Error {
  constructor() {
    super(
      "This workspace changed in another window. Download a backup of your edits, then reload the saved version.",
    );
  }
}
export interface Repository {
  get<T>(key: string): Promise<T | undefined>;
  put(key: string, value: unknown, expectedRevision?: number): Promise<void>;
  delete(key: string): Promise<void>;
  claim(key: string, ttl: number): Promise<boolean>;
}
export interface Vault {
  get(id: string): Promise<string | undefined>;
  set(id: string, value: string): Promise<void>;
  delete(id: string): Promise<void>;
}
export function encodeSnapshot(value: unknown) {
  const data = Buffer.from(JSON.stringify(value));
  const chunks: string[] = [];
  for (let i = 0; i < data.length; i += 150000)
    chunks.push(data.subarray(i, i + 150000).toString("base64"));
  return chunks;
}
export function decodeSnapshot(chunks: string[]) {
  return JSON.parse(
    Buffer.concat(chunks.map((c) => Buffer.from(c, "base64"))).toString(),
  );
}
export class DynamoRepository implements Repository {
  private client = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
    marshallOptions: { removeUndefinedValues: true },
  });
  private async raw(key: string) {
    return (
      await this.client.send(
        new GetCommand({
          TableName: process.env.TABLE_NAME,
          Key: { pk: key },
          ConsistentRead: true,
        }),
      )
    ).Item;
  }
  async get<T>(key: string) {
    const item = await this.raw(key);
    if (!item?.value?.__chunks) return item?.value as T | undefined;
    const keys = item.value.__chunks as string[];
    let requested = {
      [process.env.TABLE_NAME!]: {
        Keys: keys.map((pk) => ({ pk })),
        ConsistentRead: true,
      },
    };
    const items: Record<string, string> = {};
    for (
      let attempt = 0;
      attempt < 6 && Object.keys(requested).length;
      attempt++
    ) {
      const result = await this.client.send(
        new BatchGetCommand({ RequestItems: requested }),
      );
      for (const row of result.Responses?.[process.env.TABLE_NAME!] || [])
        items[row.pk] = row.value;
      requested = (result.UnprocessedKeys as typeof requested) || {};
      if (Object.keys(requested).length)
        await new Promise((resolve) => setTimeout(resolve, 50 * 2 ** attempt));
    }
    if (keys.some((k) => !items[k]))
      throw new Error("Could not load the complete workspace. Please retry.");
    return decodeSnapshot(keys.map((k) => items[k])) as T;
  }
  async put(key: string, value: unknown, expectedRevision?: number) {
    let payload = value,
      previous: Record<string, any> | undefined,
      newKeys: string[] = [];
    if (key.startsWith("WORKSPACE#")) {
      previous = await this.raw(key);
      if (
        previous &&
        expectedRevision !== undefined &&
        previous.value.revision !== expectedRevision
      )
        throw new Conflict();
      const w = value as {
        revision: number;
        tasks: { id: string; status: string; remindAt: string; telegramReminder?: boolean }[];
        settings: unknown;
      };
      const version = randomUUID();
      const chunks = encodeSnapshot(value);
      newKeys = chunks.map((_, i) => `CHUNK#${key}#${version}#${i}`);
      // Uncommitted chunks expire. Committed chunks have their expiry removed before the head becomes visible.
      for (let start = 0; start < chunks.length; start += 25) {
        let requests = chunks.slice(start, start + 25).map((part, i) => ({
          PutRequest: {
            Item: {
              pk: newKeys[start + i],
              value: part,
              expiresAt: Math.floor(Date.now() / 1000) + 86400,
            },
          },
        }));
        for (let attempt = 0; requests.length && attempt < 6; attempt++) {
          const result = await this.client.send(
            new BatchWriteCommand({
              RequestItems: { [process.env.TABLE_NAME!]: requests },
            }),
          );
          requests = (result.UnprocessedItems?.[process.env.TABLE_NAME!] ||
            []) as typeof requests;
          if (requests.length)
            await new Promise((resolve) =>
              setTimeout(resolve, 50 * 2 ** attempt),
            );
        }
        if (requests.length)
          throw new Error("Workspace storage is busy. Please retry.");
      }
      await Promise.all(
        newKeys.map((pk) =>
          this.client.send(
            new UpdateCommand({
              TableName: process.env.TABLE_NAME,
              Key: { pk },
              UpdateExpression: "REMOVE expiresAt",
            }),
          ),
        ),
      );
      payload = {
        __chunks: newKeys,
        revision: w.revision,
        tasks: w.tasks.map((t) => ({
          id: t.id,
          status: t.status,
          remindAt: t.remindAt,
          telegramReminder: t.telegramReminder ?? Boolean(t.remindAt),
        })),
        settings: w.settings,
      };
    }
    try {
      await this.client.send(
        new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: { pk: key, value: payload,
            ...(key.startsWith("ACTION#") ? { expiresAt: Math.floor(Date.now() / 1000) + 7 * 86400 } : {}),
            ...(key.startsWith("DELIVERY#") ? { expiresAt: Math.floor(Date.now() / 1000) + 30 * 86400 } : {}),
          },
          ...(expectedRevision !== undefined
            ? {
                ConditionExpression:
                  "attribute_not_exists(pk) OR #value.revision = :revision",
                ExpressionAttributeNames: { "#value": "value" },
                ExpressionAttributeValues: { ":revision": expectedRevision },
              }
            : {}),
        }),
      );
    } catch (e) {
      if ((e as Error).name === "ConditionalCheckFailedException") {
        await Promise.allSettled(newKeys.map((pk) => this.delete(pk)));
        throw new Conflict();
      }
      throw e;
    }
    // Retain the previous version for a week so concurrent readers can finish safely.
    await Promise.allSettled(
      (previous?.value?.__chunks || []).map((pk: string) =>
        this.client.send(
          new UpdateCommand({
            TableName: process.env.TABLE_NAME,
            Key: { pk },
            UpdateExpression: "SET expiresAt = :ttl",
            ExpressionAttributeValues: {
              ":ttl": Math.floor(Date.now() / 1000) + 7 * 86400,
            },
          }),
        ),
      ),
    );
  }
  async delete(key: string) {
    await this.client.send(
      new DeleteCommand({
        TableName: process.env.TABLE_NAME,
        Key: { pk: key },
      }),
    );
  }
  async claim(key: string, ttl: number) {
    try {
      await this.client.send(
        new PutCommand({
          TableName: process.env.TABLE_NAME,
          Item: { pk: key, expiresAt: Math.floor(Date.now() / 1000) + ttl },
          ConditionExpression: "attribute_not_exists(pk) OR expiresAt < :now",
          ExpressionAttributeValues: { ":now": Math.floor(Date.now() / 1000) },
        }),
      );
      return true;
    } catch (e) {
      if ((e as Error).name === "ConditionalCheckFailedException") return false;
      throw e;
    }
  }
}
export class SecretVault implements Vault {
  private client = new SecretsManagerClient({});
  private name(id: string) {
    return `workmate/bots/${id}`;
  }
  async get(id: string) {
    try {
      return (
        await this.client.send(
          new GetSecretValueCommand({ SecretId: this.name(id) }),
        )
      ).SecretString;
    } catch (e) {
      if ((e as Error).name === "ResourceNotFoundException") return undefined;
      throw e;
    }
  }
  async set(id: string, value: string) {
    try {
      await this.client.send(
        new PutSecretValueCommand({
          SecretId: this.name(id),
          SecretString: value,
        }),
      );
    } catch (e) {
      if ((e as Error).name !== "ResourceNotFoundException") throw e;
      await this.client.send(
        new CreateSecretCommand({ Name: this.name(id), SecretString: value }),
      );
    }
  }
  async delete(id: string) {
    try {
      await this.client.send(
        new DeleteSecretCommand({
          SecretId: this.name(id),
          ForceDeleteWithoutRecovery: true,
        }),
      );
    } catch (e) {
      if ((e as Error).name !== "ResourceNotFoundException") throw e;
    }
  }
}
