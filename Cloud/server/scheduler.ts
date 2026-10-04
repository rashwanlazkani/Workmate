import type { DynamoDBStreamEvent } from "aws-lambda";
import { unmarshall } from "@aws-sdk/util-dynamodb";
import {
  SchedulerClient,
  CreateScheduleCommand,
  UpdateScheduleCommand,
  DeleteScheduleCommand,
  type CreateScheduleCommandInput,
} from "@aws-sdk/client-scheduler";
import { createHash } from "node:crypto";
import { dateKey, notifiesTelegram, type Workspace } from "../src/model";
import { DynamoRepository, SecretVault } from "./repository";
import { Service, userHash } from "./service";
const client = new SchedulerClient({});
export const scheduleName = (user: string, id: string) =>
  "wm-" +
  createHash("sha256")
    .update(user + ":" + id)
    .digest("hex")
    .slice(0, 48);
export function reminderSchedule(
  user: string,
  task: Workspace["tasks"][number],
  now = Date.now(),
) {
  if (
    task.status === "done" ||
    !notifiesTelegram(task) ||
    !task.remindAt ||
    new Date(task.remindAt).getTime() < now - 86400000
  )
    return null;
  const at = new Date(Math.max(new Date(task.remindAt).getTime(), now + 65000))
    .toISOString()
    .slice(0, 19);
  return {
    Name: scheduleName(user, task.id),
    ScheduleExpression: `at(${at})`,
    ScheduleExpressionTimezone: "UTC",
    FlexibleTimeWindow: { Mode: "OFF" as const },
    ActionAfterCompletion: "DELETE" as const,
    Target: {
      Arn: process.env.WORKER_ARN!,
      RoleArn: process.env.SCHEDULER_ROLE_ARN!,
      Input: JSON.stringify({
        user,
        kind: "reminder",
        taskId: task.id,
        remindAt: task.remindAt,
      }),
      RetryPolicy: { MaximumEventAgeInSeconds: 3600, MaximumRetryAttempts: 3 },
      DeadLetterConfig: { Arn: process.env.DEAD_LETTER_ARN! },
    },
  };
}
async function remove(name: string) {
  try {
    await client.send(
      new DeleteScheduleCommand({
        Name: name,
        GroupName: process.env.SCHEDULE_GROUP,
      }),
    );
  } catch (e) {
    if ((e as Error).name !== "ResourceNotFoundException") throw e;
  }
}
async function upsert(input: Omit<CreateScheduleCommandInput, "GroupName">) {
  const args = { ...input, GroupName: process.env.SCHEDULE_GROUP };
  try {
    await client.send(new UpdateScheduleCommand(args));
  } catch (e) {
    if ((e as Error).name !== "ResourceNotFoundException") throw e;
    try {
      await client.send(new CreateScheduleCommand(args));
    } catch (createError) {
      if ((createError as Error).name !== "ConflictException")
        throw createError;
      await client.send(new UpdateScheduleCommand(args));
    }
  }
}
export async function planner(event: DynamoDBStreamEvent) {
  const failures: { itemIdentifier: string }[] = [];
  for (const record of event.Records) {
    try {
      if (!record.dynamodb?.NewImage) continue;
      const item = unmarshall(record.dynamodb.NewImage as any);
      if (!item.pk?.startsWith("WORKSPACE#")) continue;
      const user = item.pk.slice(10),
        next = item.value as Workspace;
      const old = record.dynamodb.OldImage
        ? (unmarshall(record.dynamodb.OldImage as any).value as Workspace)
        : undefined;
      const oldTasks = new Map(old?.tasks.map((t) => [t.id, t]) || []);
      const nextIds = new Set(next.tasks.map((t) => t.id));
      for (const task of next.tasks) {
        const before = oldTasks.get(task.id);
        if (
          before?.remindAt === task.remindAt &&
          before?.status === task.status &&
          notifiesTelegram(before) === notifiesTelegram(task)
        )
          continue;
        const schedule = reminderSchedule(user, task);
        if (schedule) await upsert(schedule);
        else if (before?.remindAt) await remove(scheduleName(user, task.id));
      }
      for (const task of old?.tasks || [])
        if (task.remindAt && !nextIds.has(task.id))
          await remove(scheduleName(user, task.id));
      if (
        !old ||
        JSON.stringify(old.settings) !== JSON.stringify(next.settings)
      ) {
        const name = scheduleName(user, "digest");
        if (next.settings.digestEnabled) {
          const [hour, minute] = next.settings.digestTime.split(":");
          await upsert({
            Name: name,
            ScheduleExpression: `cron(${Number(minute)} ${Number(hour)} * * ? *)`,
            ScheduleExpressionTimezone: next.settings.timezone,
            FlexibleTimeWindow: { Mode: "OFF" },
            Target: {
              Arn: process.env.WORKER_ARN!,
              RoleArn: process.env.SCHEDULER_ROLE_ARN!,
              Input: JSON.stringify({ user, kind: "digest" }),
              RetryPolicy: {
                MaximumEventAgeInSeconds: 3600,
                MaximumRetryAttempts: 3,
              },
              DeadLetterConfig: { Arn: process.env.DEAD_LETTER_ARN! },
            },
          });
        } else await remove(name);
      }
    } catch (e) {
      console.error("Schedule reconciliation failed", {
        type: (e as Error).name,
      });
      failures.push({
        itemIdentifier: record.dynamodb?.SequenceNumber || record.eventID!,
      });
    }
  }
  return { batchItemFailures: failures };
}
const service = new Service(new DynamoRepository(), new SecretVault(), "cloud");
export async function worker(event: {
  user: string;
  kind: "reminder" | "digest";
  taskId?: string;
  remindAt?: string;
  date?: string;
}) {
  const w = await service.repo.get<Workspace>("WORKSPACE#" + event.user);
  if (!w) return;
  await service.deliver({
    ...event,
    date: dateKey(new Date(), w.settings.timezone),
  });
}
