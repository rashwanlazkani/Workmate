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
import { DateTime } from "luxon";
import { notificationPlan } from "./notifications";
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
export function meetingSchedules(user: string, workspace: Workspace, now = Date.now(), includeExpired = false): Omit<CreateScheduleCommandInput, "GroupName">[] {
  const schedules: Omit<CreateScheduleCommandInput, "GroupName">[] = [];
  for (const meeting of workspace.meetings ?? []) {
    if (meeting.canceled || !meeting.reminderEnabled) continue;
    const start = DateTime.fromISO(meeting.startAt, { zone: meeting.timezone });
    const base = (suffix: string, startAt?: string) => ({
      Name: scheduleName(user, "meeting:" + meeting.id + ":" + suffix),
      FlexibleTimeWindow: { Mode: "OFF" as const },
      Target: {
        Arn: process.env.WORKER_ARN!, RoleArn: process.env.SCHEDULER_ROLE_ARN!,
        Input: JSON.stringify({ user, kind: "meeting", meetingId: meeting.id, ...(startAt ? { startAt } : {}) }),
        RetryPolicy: { MaximumEventAgeInSeconds: 3600, MaximumRetryAttempts: 3 },
        DeadLetterConfig: { Arn: process.env.DEAD_LETTER_ARN! },
      },
    });
    if (meeting.recurrence !== "weekly") {
      if (!includeExpired && Math.min(Date.parse(meeting.endAt), start.plus({ minutes: 5 }).toMillis()) <= now) continue;
      const fire = Math.max(start.minus({ minutes: meeting.reminderMinutes }).toMillis(), now + 65000);
      schedules.push({ ...base("once", start.toUTC().toISO({ suppressMilliseconds: true })!),
        ScheduleExpression: `at(${new Date(fire).toISOString().slice(0, 19)})`, ScheduleExpressionTimezone: "UTC", ActionAfterCompletion: "DELETE" });
      continue;
    }
    const rules = meeting.weeklySchedule ?? (meeting.weekdays ?? [start.weekday % 7 + 1]).map(weekday => ({ weekday, startTime: start.toFormat("HH:mm"), endTime: "" }));
    for (const rule of rules) {
      const [hour, minute] = rule.startTime.split(":").map(Number);
      const fire = DateTime.utc(2026, 1, 4).plus({ days: rule.weekday - 1 }).set({ hour, minute }).minus({ minutes: meeting.reminderMinutes });
      schedules.push({ ...base(String(rule.weekday)),
        ScheduleExpression: `cron(${fire.minute} ${fire.hour} ? * ${fire.weekday % 7 + 1} *)`,
        ScheduleExpressionTimezone: meeting.timezone,
        StartDate: new Date(Math.max(now, start.minus({ minutes: meeting.reminderMinutes }).toMillis())),
      });
    }
  }
  return schedules;
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
      if (JSON.stringify(old?.meetings) !== JSON.stringify(next.meetings)) {
      const previousMeetings = meetingSchedules(user, old ?? { ...next, meetings: [] }, Date.now(), true);
      const schedules = meetingSchedules(user, next);
      const names = new Set(schedules.map(s => s.Name));
      for (const schedule of schedules) await upsert(schedule);
      for (const schedule of previousMeetings) if (!names.has(schedule.Name)) await remove(schedule.Name!);
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
  kind: "reminder" | "digest" | "meeting";
  meetingId?: string;
  startAt?: string;
  taskId?: string;
  remindAt?: string;
  date?: string;
}) {
  const w = await service.repo.get<Workspace>("WORKSPACE#" + event.user);
  if (!w) return;
  if (event.kind === "meeting" && !event.startAt) {
    // Recurring cron invocations resolve the current occurrence from authoritative data.
    const occurrence = notificationPlan(w).find(job => job.kind === "meeting" && job.meetingId === event.meetingId && Date.parse(job.fireAt) <= Date.now());
    if (!occurrence) return;
    event.startAt = occurrence.startAt;
  }
  await service.deliver({
    ...event,
    date: dateKey(new Date(), w.settings.timezone),
  });
}
