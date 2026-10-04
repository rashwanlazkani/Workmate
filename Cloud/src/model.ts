import { z } from "zod";
export const priorities = ["low", "medium", "high", "urgent"] as const;
export type Priority = (typeof priorities)[number];
export const priorityLabel: Record<Priority, string> = {
  low: "Low",
  medium: "Medium",
  high: "High",
  urgent: "Urgent",
};
export const priorityRank: Record<Priority, number> = {
  low: 0,
  medium: 1,
  high: 2,
  urgent: 3,
};
export const taskSchema = z.object({
  id: z.string().uuid(),
  title: z.string().min(1).max(500),
  project: z.string().max(80),
  status: z.enum(["inbox", "todo", "done"]),
  priority: z.preprocess(
    (value) => (value === "normal" ? "medium" : value),
    z.enum(priorities),
  ),
  focus: z.boolean(),
  due: z.string().regex(/^$|^\d{4}-\d{2}-\d{2}$/),
  remindAt: z.string().datetime().or(z.literal("")),
  telegramReminder: z.boolean().optional(),
  noteId: z.string(),
  meetingId: z.string().uuid().optional(),
  tags: z.array(z.string().max(200).transform(v => v.trim().replace(/^#+/, "").trim().replace(/\s+/g, " ").toLowerCase())).max(20)
    .transform(v => [...new Set(v.filter(Boolean))]).optional(),
  createdAt: z.string(),
  completedAt: z.string().optional(),
});
export const noteSectionSchema = z.object({
  id: z.string().uuid(),
  title: z.string().max(200),
  body: z.string().max(60000),
  richText: z.string().max(800000).optional(),
});
export const noteSchema = z.object({
  id: z.string().uuid(),
  title: z.string().max(200),
  body: z.string().max(60000),
  richText: z.string().max(800000).optional(),
  sections: z.array(noteSectionSchema).min(1).max(50).refine((sections) => new Set(sections.map((section) => section.id)).size === sections.length).optional(),
  project: z.string().max(80),
  updatedAt: z.string(),
  pinned: z.boolean(),
  meetingIds: z.array(z.string().uuid()).max(500).optional(),
});
export const meetingSchema = z
  .object({
    id: z.string().uuid(),
    title: z.string().min(1).max(200),
    startAt: z.string().datetime(),
    endAt: z.string().datetime(),
    timezone: z.string().refine((v) => {
      try {
        new Intl.DateTimeFormat("en", { timeZone: v });
        return true;
      } catch {
        return false;
      }
    }),
    recurrence: z.enum(["none", "weekly"]),
    weekdays: z.array(z.number().int().min(1).max(7)).min(1).max(7).refine(v => new Set(v).size === v.length).optional(),
    weeklySchedule: z.array(z.object({ weekday: z.number().int().min(1).max(7), startTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/), endTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/) })).min(1).max(7).refine(v => new Set(v.map(d => d.weekday)).size === v.length).optional(),
    reminderMinutes: z.number().int().min(0).max(120),
    reminderEnabled: z.boolean(),
    calendarEventId: z.string().max(1000),
    calendarId: z.string().max(1000),
    calendarName: z.string().max(200),
    location: z.string().max(1000),
    canceled: z.boolean(),
  })
  .refine(
    (v) => new Date(v.endAt) > new Date(v.startAt),
    "Meeting must end after it starts",
  );
export const nodeSchema = z.object({
  id: z.string().uuid(),
  text: z.string().max(120),
  x: z.number().min(0).max(2000),
  y: z.number().min(0).max(2000),
  parent: z.string().nullable(),
  color: z.enum(["green", "blue", "orange", "pink"]),
});
export const strokeSchema = z.object({
  id: z.string(),
  points: z.array(z.tuple([z.number(), z.number()])).max(3000),
});
export const workspaceSchema = z.object({
  tasks: z.array(taskSchema).max(1000),
  notes: z.array(noteSchema).max(300),
  nodes: z.array(nodeSchema).max(100),
  strokes: z.array(strokeSchema).max(100),
  settings: z.object({
    name: z.string().max(80),
    timezone: z.string().refine((v) => {
      try {
        new Intl.DateTimeFormat("en", { timeZone: v });
        return true;
      } catch {
        return false;
      }
    }, "Choose a valid IANA timezone"),
    digestEnabled: z.boolean(),
    digestTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
    browserNotifications: z.boolean(),
    digestPriorities: z
      .array(z.enum(priorities))
      .min(1)
      .max(4)
      .refine((v) => new Set(v).size === v.length)
      .default(["low", "medium", "high", "urgent"]),
  }),
  sample: z.boolean(),
  revision: z.number().int().nonnegative(),
  meetings: z.array(meetingSchema).max(500).optional(),
});
export type Task = z.infer<typeof taskSchema>;
export type Note = z.infer<typeof noteSchema>;
export type MindNode = z.infer<typeof nodeSchema>;
export type Stroke = z.infer<typeof strokeSchema>;
export type Workspace = z.infer<typeof workspaceSchema>;
export function dateKey(
  date = new Date(),
  timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone,
) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}
export function dayOffset(n: number) {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return dateKey(d);
}
export function newTask(title: string, values: Partial<Task> = {}): Task {
  return {
    id: crypto.randomUUID(),
    title,
    project: "",
    status: "inbox",
    priority: "medium",
    focus: false,
    due: "",
    remindAt: "",
    telegramReminder: false,
    noteId: "",
    createdAt: new Date().toISOString(),
    ...values,
  };
}
export function notifiesTelegram(task: Pick<Task, "remindAt" | "telegramReminder">): boolean {
  return task.telegramReminder ?? Boolean(task.remindAt);
}
export function newNote(
  title = "Untitled note",
  body = "",
  project = "",
): Note {
  return {
    id: crypto.randomUUID(),
    title,
    body,
    project,
    updatedAt: new Date().toISOString(),
    pinned: false,
  };
}
export function emptyWorkspace(): Workspace {
  return {
    tasks: [],
    notes: [],
    nodes: [],
    strokes: [],
    settings: {
      name: "",
      timezone: "Europe/Stockholm",
      digestEnabled: false,
      digestTime: "08:30",
      browserNotifications: false,
      digestPriorities: [...priorities],
    },
    sample: false,
    revision: 0,
  };
}
export function sampleWorkspace(): Workspace {
  const note = newNote(
    "A little room to think",
    "A calmer way to start the week\n\nUse this space for meeting notes, loose thoughts, and the things you don’t want to forget.\n\nToday’s intention\nDo fewer things, with a little more focus.\n\nNext actions\n- [ ] Review the project timeline\n- [ ] Send a follow-up after the team meeting\n\nTip: select text and choose “Create task” to give any thought a next step.",
    "Getting started",
  );
  note.pinned = true;
  const root = crypto.randomUUID();
  return {
    ...emptyWorkspace(),
    sample: true,
    notes: [
      note,
      newNote(
        "Ideas for a better workday",
        "One inbox for everything.\nA short list for today.\nEnough space for the bigger picture.",
        "Getting started",
      ),
    ],
    tasks: [
      newTask("Make room for your most important work", {
        status: "todo",
        focus: true,
        due: dayOffset(0),
        project: "Getting started",
        priority: "high",
        noteId: note.id,
      }),
      newTask("Turn a meeting note into a next action", {
        status: "todo",
        focus: true,
        due: dayOffset(0),
        project: "Getting started",
        noteId: note.id,
      }),
      newTask("Connect Telegram for a gentle nudge", {
        status: "todo",
        due: dayOffset(1),
        project: "Getting started",
      }),
      newTask("An idea you can come back to later", {
        project: "Getting started",
      }),
    ],
    nodes: [
      {
        id: root,
        text: "A calmer workday",
        x: 420,
        y: 280,
        parent: null,
        color: "green",
      },
      {
        id: crypto.randomUUID(),
        text: "Capture the loose ends",
        x: 120,
        y: 120,
        parent: root,
        color: "blue",
      },
      {
        id: crypto.randomUUID(),
        text: "Choose what matters",
        x: 730,
        y: 160,
        parent: root,
        color: "orange",
      },
      {
        id: crypto.randomUUID(),
        text: "Make space to think",
        x: 500,
        y: 470,
        parent: root,
        color: "pink",
      },
    ],
  };
}
export function summary(w: Workspace, now = new Date()) {
  const today = dateKey(now, w.settings.timezone);
  const open = w.tasks.filter((t) => t.status !== "done");
  return {
    today,
    open: open.length,
    overdue: open.filter((t) => t.due && t.due < today),
    due: open.filter((t) => t.due === today),
    focus: open.filter((t) => t.focus),
    completed: w.tasks.filter(
      (t) =>
        t.status === "done" &&
        t.completedAt &&
        dateKey(new Date(t.completedAt), w.settings.timezone) === today,
    ),
  };
}
export function dailyBriefTasks(w: Workspace): Task[] {
  const normalized = workspaceSchema.parse(w);
  return normalized.tasks
    .filter(
      (t) =>
        t.status !== "done" &&
        normalized.settings.digestPriorities.includes(t.priority),
    )
    .sort(
      (a, b) =>
        priorityRank[b.priority] - priorityRank[a.priority] ||
        (a.due || "9999").localeCompare(b.due || "9999"),
    );
}
export function digest(w: Workspace, now = new Date()) {
  const tasks = dailyBriefTasks(w),
    today = dateKey(now, w.settings.timezone);
  const selected = w.settings.digestPriorities || [...priorities];
  const included = [...selected]
    .sort((a, b) => priorityRank[b] - priorityRank[a])
    .map((p) => priorityLabel[p])
    .join(", ");
  const lines = tasks.slice(0, 16).map(t => `• [${priorityLabel[t.priority]}] ${t.title.slice(0, 160)}`);
  return [
    "Your Workmate daily brief",
    `Priorities: ${included}`,
    `${tasks.length} open ${tasks.length === 1 ? "action" : "actions"}`,
    "",
    lines.length ? lines.join("\n") : "No open actions with these priorities.",
    tasks.length > 16 ? `\n+ ${tasks.length - 16} more in Workmate` : "",
  ]
    .filter((v, i) => v || i === 3)
    .join("\n");
}
export function extractActions(body: string) {
  return body
    .split("\n")
    .map((line) =>
      line
        .match(/^\s*(?:[-*]\s*\[ \]\s*|(?:TODO|ACTION|NEXT):\s*)(.+)$/i)?.[1]
        ?.trim(),
    )
    .filter((x): x is string => Boolean(x));
}

/** Remove only unchanged starter examples. User edits, reminders and canvas data survive. */
export function withoutStarterContent(w: Workspace): Workspace {
  if (!w.sample) return w;
  const example = sampleWorkspace();
  const notes = w.notes.filter(
    (n) =>
      !example.notes.some(
        (e) =>
          n.title === e.title &&
          n.body === e.body &&
          n.project === e.project &&
          n.pinned === e.pinned,
      ),
  );
  const tasks = w.tasks
    .filter((t) => {
      const index = example.tasks.findIndex((e) => e.title === t.title);
      if (index < 0) return true;
      const e = example.tasks[index];
      const due = new Date(t.createdAt);
      due.setDate(due.getDate() + (index === 2 ? 1 : 0));
      const unchangedDue = !e.due
        ? !t.due
        : [dateKey(due, w.settings.timezone), dateKey(due, "UTC")].includes(
            t.due,
          );
      return !(
        t.project === e.project &&
        t.status === e.status &&
        t.priority === e.priority &&
        t.focus === e.focus &&
        t.remindAt === e.remindAt &&
        !t.completedAt &&
        unchangedDue
      );
    })
    .map((t) =>
      t.noteId && !notes.some((n) => n.id === t.noteId)
        ? { ...t, noteId: "" }
        : t,
    );
  return { ...w, notes, tasks, sample: false };
}
