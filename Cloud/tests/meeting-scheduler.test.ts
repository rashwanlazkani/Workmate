import { afterEach, expect, it, vi } from "vitest";
import { SchedulerClient, DeleteScheduleCommand, UpdateScheduleCommand } from "@aws-sdk/client-scheduler";
import { marshall } from "@aws-sdk/util-dynamodb";
import { emptyWorkspace, workspaceSchema } from "../src/model";
import { meetingSchedules, planner } from "../server/scheduler";
const now = Date.parse("2026-10-05T06:00:00Z");
function workspace() {
  return workspaceSchema.parse({ ...emptyWorkspace(), meetings: [{
    id: "01234567-89ab-4cde-abcd-0123456789ab", title: "Weekly sync", startAt: "2026-10-05T07:00:00Z", endAt: "2026-10-05T08:00:00Z", timezone: "Europe/Stockholm", recurrence: "weekly", reminderMinutes: 10, reminderEnabled: true, canceled: false,
    calendarEventId: "", calendarId: "", calendarName: "", location: "",
    weeklySchedule: [{ weekday: 2, startTime: "09:00", endTime: "10:00" }, { weekday: 4, startTime: "13:00", endTime: "14:30" }],
  }] });
}
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers(); });
it("schedules independent recurring weekdays in the meeting timezone", () => {
  const schedules = meetingSchedules("owner", workspace(), now);
  expect(schedules.map(s => s.ScheduleExpression)).toEqual(["cron(50 8 ? * 2 *)", "cron(50 12 ? * 4 *)"]);
  expect(schedules.every(s => s.ScheduleExpressionTimezone === "Europe/Stockholm")).toBe(true);
  expect(JSON.parse(schedules[0].Target!.Input!)).toMatchObject({ kind: "meeting", meetingId: workspace().meetings![0].id });
});
it("moves reminders before midnight to the previous weekday", () => {
  const w = workspace(); w.meetings![0].weeklySchedule = [{ weekday: 1, startTime: "00:05", endTime: "01:00" }];
  expect(meetingSchedules("owner", w, now)[0].ScheduleExpression).toBe("cron(55 23 ? * 7 *)");
});
it("does not recreate expired or canceled one-time meetings", () => {
  const w = workspace(); w.meetings![0].recurrence = "none";
  expect(meetingSchedules("owner", w, now)).toHaveLength(1);
  expect(meetingSchedules("owner", w, now + 86400000)).toHaveLength(0);
  expect(meetingSchedules("owner", w, now + 86400000, true)).toHaveLength(1);
  w.meetings![0].canceled = true;
  expect(meetingSchedules("owner", w, now)).toHaveLength(0);
});
it("removes obsolete weekday schedules without touching unchanged meetings on note edits", async () => {
  vi.useFakeTimers(); vi.setSystemTime(now);
  const send = vi.spyOn(SchedulerClient.prototype, "send").mockResolvedValue({} as never);
  const old = workspace(), next = workspace(); next.meetings![0].weeklySchedule = next.meetings![0].weeklySchedule!.slice(0,1);
  const event = (before: unknown, after: unknown): any => ({ Records: [{ eventID: "test", dynamodb: { SequenceNumber: "1", OldImage: marshall({ pk: "WORKSPACE#owner", value: before }, { removeUndefinedValues: true }), NewImage: marshall({ pk: "WORKSPACE#owner", value: after }, { removeUndefinedValues: true }) } }] });
  expect(await planner(event(old, next))).toEqual({ batchItemFailures: [] });
  expect(send.mock.calls.some(([command]) => command instanceof DeleteScheduleCommand)).toBe(true);
  expect(send.mock.calls.some(([command]) => command instanceof UpdateScheduleCommand)).toBe(true);
  send.mockClear(); await planner(event(next, { ...next, revision: next.revision + 1 }));
  expect(send).not.toHaveBeenCalled();
});
