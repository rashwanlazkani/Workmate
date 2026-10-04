import { afterEach, describe, expect, it, vi } from "vitest";
import { SchedulerClient, DeleteScheduleCommand, UpdateScheduleCommand } from "@aws-sdk/client-scheduler";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { marshall } from "@aws-sdk/util-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";
import { emptyWorkspace, newTask, notifiesTelegram, workspaceSchema, type Workspace } from "../src/model";
import { DynamoRepository, type Repository, type Vault } from "../server/repository";
import { Service } from "../server/service";
import { planner, reminderSchedule } from "../server/scheduler";

afterEach(() => vi.restoreAllMocks());

function stream(before: unknown, after: unknown): DynamoDBStreamEvent {
  return { Records: [{ eventID: "change", dynamodb: {
    SequenceNumber: "1",
    OldImage: marshall({ pk: "WORKSPACE#test", value: before }),
    NewImage: marshall({ pk: "WORKSPACE#test", value: after }),
  } }] } as unknown as DynamoDBStreamEvent;
}

describe("per-action reminder channels", () => {
  it("keeps Mac-only reminders out of Telegram schedules and preserves the flag in API parsing", () => {
    const now = Date.parse("2026-11-04T10:00:00Z");
    const task = newTask("Agenda", { remindAt: "2026-11-04T12:00:00.000Z" });
    expect(reminderSchedule("test", task, now)).toBeNull();
    const parsed = workspaceSchema.parse({ ...emptyWorkspace(), tasks: [{ ...task, telegramReminder: true }] });
    expect(parsed.tasks[0].telegramReminder).toBe(true);
    expect(reminderSchedule("test", parsed.tasks[0], now)).not.toBeNull();
    const { telegramReminder, ...legacy } = task;
    expect(notifiesTelegram(legacy)).toBe(true);
    expect(notifiesTelegram({ ...legacy, remindAt: "" })).toBe(false);
  });

  it("reconciles switching Telegram on without changing the reminder time", async () => {
    const send = vi.spyOn(SchedulerClient.prototype, "send").mockResolvedValue({} as never);
    const task = newTask("Agenda", { remindAt: new Date(Date.now() + 3600000).toISOString() });
    const before = { ...emptyWorkspace(), tasks: [task] };
    const after = { ...before, tasks: [{ ...task, telegramReminder: true }] };
    expect(await planner(stream(before, after))).toEqual({ batchItemFailures: [] });
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toBeInstanceOf(UpdateScheduleCommand);
  });

  it("carries the choice through DynamoDB's manifest and cancels Telegram when disabled", async () => {
    const storage = vi.spyOn(DynamoDBDocumentClient.prototype, "send").mockResolvedValue({} as never);
    const task = newTask("Agenda", { remindAt: new Date(Date.now() + 3600000).toISOString(), telegramReminder: false });
    const workspace = { ...emptyWorkspace(), tasks: [task] };
    await new DynamoRepository().put("WORKSPACE#test", workspace);
    const put = storage.mock.calls.map(([command]) => command).find((command) => command instanceof PutCommand) as PutCommand;
    const manifest = put.input.Item!.value;
    expect(manifest.tasks[0].telegramReminder).toBe(false);
    expect(manifest.tasks[0].remindAt).toBe(task.remindAt);
    const send = vi.spyOn(SchedulerClient.prototype, "send").mockResolvedValue({} as never);
    const before = { ...manifest, tasks: [{ ...manifest.tasks[0], telegramReminder: true }] };
    expect(await planner(stream(before, manifest))).toEqual({ batchItemFailures: [] });
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toBeInstanceOf(DeleteScheduleCommand);
  });

  it("suppresses already-queued Telegram deliveries after opting out", async () => {
    const task = newTask("Agenda", { remindAt: "2026-11-04T12:00:00.000Z", telegramReminder: false });
    const workspace: Workspace = { ...emptyWorkspace(), tasks: [task] };
    const repo: Repository = {
      async get<T>(key: string) { return (key.startsWith("WORKSPACE#") ? workspace : { chatId: 123 }) as T; },
      async put() {}, async delete() {}, async claim() { return true; },
    };
    const vault: Vault = { async get() { return undefined; }, async set() {}, async delete() {} };
    const service = new Service(repo, vault, "cloud");
    const send = vi.spyOn(service, "send").mockResolvedValue();
    const event = { user: "test", kind: "reminder" as const, taskId: task.id, remindAt: task.remindAt };
    await service.deliver(event);
    expect(send).not.toHaveBeenCalled();
    workspace.tasks[0].telegramReminder = true;
    await service.deliver(event);
    expect(send).toHaveBeenCalledTimes(1);
  });
});
