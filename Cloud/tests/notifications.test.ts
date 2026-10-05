import { afterEach, expect, it, vi } from "vitest";
import { emptyWorkspace, newTask, workspaceSchema } from "../src/model";
import { notificationPlan } from "../server/notifications";
import { Service, userHash, type Bot } from "../server/service";
import type { Repository } from "../server/repository";

function memory() {
  const values = new Map<string, any>(); const claims = new Map<string, number>();
  const repo: Repository = {
    async get<T>(key: string) { return values.get(key) as T; },
    async put(key, data) { values.set(key, data); },
    async delete(key) { values.delete(key); claims.delete(key); },
    async claim(key, ttl) { if ((claims.get(key) ?? 0) > Date.now() || values.has(key)) return false; claims.set(key, Date.now() + ttl * 1000); return true; },
  };
  return { repo, values };
}
const user = "drive-01234567-89ab-4cde-abcd-0123456789ab";
const hash = userHash(user);
function setup() {
  const { repo, values } = memory();
  const w = emptyWorkspace();
  w.tasks = [newTask("Prepare PO-sync agenda", { remindAt: "2026-10-07T11:00:00Z", telegramReminder: true, priority: "high" })];
  values.set("WORKSPACE#" + user, w);
  values.set("BOT#" + hash, { user, chatId: 123, botName: "test", pairCode: "", pairExpires: 0 } satisfies Bot);
  const service = new Service(repo, { async get() { return "test-token"; }, async set() {}, async delete() {} }, "local");
  const calls: { method: string, data: any }[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: string, options: RequestInit) => {
    calls.push({ method: url.split("/").pop()!, data: JSON.parse(options.body as string) });
    return { json: async () => ({ ok: true, result: {} }) };
  }));
  return { repo, service, values, w, calls };
}
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers(); });
it("uses different weekday times, midnight and DST without losing legacy weekly meetings", () => {
  const w = workspaceSchema.parse({ ...emptyWorkspace(), meetings: [{
    id: "01234567-89ab-4cde-abcd-0123456789ab", title: "Team sync", startAt: "2026-10-19T07:00:00Z", endAt: "2026-10-19T08:00:00Z", timezone: "Europe/Stockholm", recurrence: "weekly", reminderMinutes: 10, reminderEnabled: true, canceled: false, calendarEventId: "", calendarId: "", calendarName: "", location: "",
    weeklySchedule: [{ weekday: 2, startTime: "09:00", endTime: "10:00" }, { weekday: 4, startTime: "13:00", endTime: "14:30" }, { weekday: 6, startTime: "23:30", endTime: "00:30" }],
  }] });
  let jobs = notificationPlan(w, Date.parse("2026-10-21T00:00:00Z"));
  expect(jobs.map(j => j.startAt)).toEqual(["2026-10-21T11:00:00Z", "2026-10-23T21:30:00Z", "2026-10-26T08:00:00Z", "2026-10-28T12:00:00Z"]);
  expect(jobs[1].endAt).toBe("2026-10-23T22:30:00Z");
  expect(jobs[2].fireAt).toBe("2026-10-26T07:50:00Z");
  delete w.meetings![0].weeklySchedule;
  jobs = notificationPlan(w, Date.parse("2026-10-21T00:00:00Z"));
  expect(jobs.map(j => j.startAt)).toEqual(["2026-10-26T08:00:00Z"]);
});
it("archives a task, confirms it in the message, and ignores duplicate updates", async () => {
  const { service, w, calls } = setup();
  const update = { update_id: 1, callback_query: { id: "callback", data: "done:" + w.tasks[0].id, message: { message_id: 9, chat: { id: 123 } } } };
  await service.incoming(hash, update);
  const archived = (await service.workspace(user)).tasks[0];
  expect(archived.status).toBe("done"); expect(archived.completedAt).toBeTruthy();
  expect(calls.find(c => c.method === "editMessageText")?.data).toMatchObject({ message_id: 9, reply_markup: { inline_keyboard: [] } });
  expect(calls.find(c => c.method === "answerCallbackQuery")?.data.text).toContain("Archive");
  const count = calls.length; await service.incoming(hash, update); expect(calls).toHaveLength(count);
});
it("snoozes exactly one hour, cancels the stale delivery, and never reopens archived tasks", async () => {
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-07T11:00:00Z"));
  const { service, w, calls } = setup();
  const update = { update_id: 2, callback_query: { id: "callback", data: "snooze:" + w.tasks[0].id, message: { message_id: 9, chat: { id: 123 } } } };
  await service.incoming(hash, update);
  expect((await service.workspace(user)).tasks[0].remindAt).toBe("2026-10-07T12:00:00.000Z");
  expect(await service.deliver({ user, kind: "reminder", taskId: w.tasks[0].id, remindAt: w.tasks[0].remindAt })).toBe("skipped");
  expect(calls.some(c => c.method === "sendMessage")).toBe(false);
  await service.incoming(hash, { ...update, update_id: 3, callback_query: { ...update.callback_query, data: "done:" + w.tasks[0].id } });
  await service.incoming(hash, { ...update, update_id: 4 });
  expect((await service.workspace(user)).tasks[0].status).toBe("done");
});
it("rejects a different chat and an unknown task without pretending to complete it", async () => {
  const { service, w, calls } = setup();
  await service.incoming(hash, { update_id: 1, callback_query: { id: "x", data: "done:" + w.tasks[0].id, message: { chat: { id: 456 } } } });
  expect(calls).toHaveLength(0);
  await service.incoming(hash, { update_id: 2, callback_query: { id: "x", data: "done:01234567-89ab-4cde-abcd-0123456789ab", message: { chat: { id: 123 } } } });
  expect(calls[0].data.text).toContain("no longer available");
  expect((await service.workspace(user)).tasks[0].status).toBe("inbox");
});
it("deduplicates AWS deliveries, with clear text and both actions", async () => {
  const { service, w, calls } = setup();
  const event = { user, kind: "reminder" as const, taskId: w.tasks[0].id, remindAt: w.tasks[0].remindAt };
  expect(await service.deliver(event)).toBe("delivered");
  expect(await service.deliver(event)).toBe("duplicate");
  expect(calls).toHaveLength(1); expect(calls[0].data.text).toContain("High priority");
  expect(calls[0].data.text).not.toContain("nudge");
  expect(calls[0].data.reply_markup.inline_keyboard[0].map((b: any) => b.text)).toEqual(["Mark complete", "Snooze 1 hour"]);
});
it("normalizes task tags and preserves legacy tasks without tags", () => {
  const w = workspaceSchema.parse({ ...emptyWorkspace(), tasks: [{ ...newTask("Agenda"), tags: [" #PO-Sync ", "po-sync", "RELEASE   Planning"] }, newTask("Legacy")] });
  expect(w.tasks[0].tags).toEqual(["po-sync", "release planning"]);
  expect(w.tasks[1].tags).toBeUndefined();
});
