import { createHash } from "node:crypto";
import { DateTime } from "luxon";
import { notifiesTelegram, type Workspace } from "../src/model";

export type NotificationJob = {
  id: string; kind: "reminder" | "digest" | "meeting";
  fireAt: string; expiresAt: string;
  taskId?: string; remindAt?: string; date?: string;
  meetingId?: string; startAt?: string; endAt?: string;
};
type Draft = Omit<NotificationJob, "id">;
function job(draft: Draft): NotificationJob {
  const identity = [draft.kind, draft.taskId ?? draft.meetingId ?? "", draft.remindAt ?? draft.startAt ?? draft.date, draft.fireAt].join("|");
  return { ...draft, id: createHash("sha256").update(identity).digest("hex") };
}
const iso = (date: DateTime) => date.toUTC().toISO({ suppressMilliseconds: true })!;
const weekday = (date: DateTime) => date.weekday % 7 + 1;
// Match Calendar's nextTime/first policy: spring gaps advance to the first valid minute,
// and the first occurrence wins when a local clock time occurs twice in autumn.
export function localClock(day: DateTime, time: string) {
  const [hour, minute] = time.split(":").map(Number);
  let date = day.set({ hour, minute, second: 0, millisecond: 0 });
  if (date.hour !== hour || date.minute !== minute) date = date.startOf("hour");
  return date.getPossibleOffsets().sort((a, b) => a.toMillis() - b.toMillis())[0] ?? date;
}
export function notificationPlan(w: Workspace, now = Date.now()): NotificationJob[] {
  const jobs: NotificationJob[] = [];
  const horizon = now + 8 * 86400000;
  const add = (draft: Draft) => {
    if (Date.parse(draft.fireAt) < horizon && Date.parse(draft.expiresAt) > now) jobs.push(job(draft));
  };
  for (const task of w.tasks) {
    if (task.status === "done" || !notifiesTelegram(task) || !task.remindAt) continue;
    const fire = DateTime.fromISO(task.remindAt);
    add({ kind: "reminder", taskId: task.id, remindAt: task.remindAt, fireAt: iso(fire), expiresAt: iso(fire.plus({ hours: 24 })) });
  }
  if (w.settings.digestEnabled) {
    const today = DateTime.fromMillis(now, { zone: w.settings.timezone }).startOf("day");
    for (let offset = -1; offset <= 8; offset++) {
      const fire = localClock(today.plus({ days: offset }), w.settings.digestTime);
      add({ kind: "digest", date: fire.toISODate()!, fireAt: iso(fire), expiresAt: iso(fire.plus({ hours: 6 })) });
    }
  }
  for (const meeting of w.meetings ?? []) {
    if (meeting.canceled || !meeting.reminderEnabled) continue;
    const anchor = DateTime.fromISO(meeting.startAt, { zone: meeting.timezone });
    const anchorEnd = DateTime.fromISO(meeting.endAt, { zone: meeting.timezone });
    const occurrence = (start: DateTime, end: DateTime) => {
      if (start < anchor || end <= start) return;
      add({ kind: "meeting", meetingId: meeting.id, startAt: iso(start), endAt: iso(end),
        fireAt: iso(start.minus({ minutes: meeting.reminderMinutes })),
        expiresAt: iso(DateTime.min(end, start.plus({ minutes: 5 }))) });
    };
    if (meeting.recurrence !== "weekly") { occurrence(anchor, anchorEnd); continue; }
    const rules = meeting.weeklySchedule ?? (meeting.weekdays ?? [weekday(anchor)]).map(day => ({ weekday: day, startTime: anchor.toFormat("HH:mm"), endTime: anchorEnd.toFormat("HH:mm") }));
    const today = DateTime.fromMillis(now, { zone: meeting.timezone }).startOf("day");
    for (let offset = -1; offset <= 9; offset++) {
      const day = today.plus({ days: offset });
      const rule = rules.find(r => r.weekday === weekday(day));
      if (!rule) continue;
      const start = localClock(day, rule.startTime);
      const endDay = rule.endTime <= rule.startTime ? day.plus({ days: 1 }) : day;
      occurrence(start, localClock(endDay, rule.endTime));
    }
  }
  return jobs.sort((a, b) => a.fireAt.localeCompare(b.fireAt));
}
export function formatTime(value: string, timezone: string) {
  return DateTime.fromISO(value, { zone: timezone }).toFormat("ccc d LLL, HH:mm");
}
