import { describe, it, expect, beforeEach, vi } from "vitest";
import {
  extractActions,
  digest,
  dailyBriefTasks,
  sampleWorkspace,
  withoutStarterContent,
  emptyWorkspace,
  newTask,
  summary,
  workspaceSchema,
  type Workspace,
} from "../src/model";
import { Service, userHash, type Bot } from "../server/service";
import {
  Conflict,
  encodeSnapshot,
  decodeSnapshot,
  type Repository,
  type Vault,
} from "../server/repository";
import { reminderSchedule } from "../server/scheduler";
class MemoryRepo implements Repository {
  db = new Map<string, any>();
  async get<T>(key: string) {
    return structuredClone(this.db.get(key)) as T | undefined;
  }
  async put(key: string, value: unknown, revision?: number) {
    if (
      revision !== undefined &&
      this.db.has(key) &&
      this.db.get(key).revision !== revision
    )
      throw new Conflict();
    this.db.set(key, structuredClone(value));
  }
  async delete(key: string) {
    this.db.delete(key);
  }
  async claim(key: string, ttl: number) {
    if (this.db.get(key)?.expiresAt > Date.now()) return false;
    this.db.set(key, { expiresAt: Date.now() + ttl * 1000 });
    return true;
  }
}
const vault: Vault = {
  get: async () => "123456:server-only-token",
  set: async () => {},
  delete: async () => {},
};
let repo: MemoryRepo, service: Service;
beforeEach(() => {
  repo = new MemoryRepo();
  service = new Service(repo, vault, "cloud");
  vi.restoreAllMocks();
});
describe("workspace integrity", () => {
  it("isolates users and refuses stale saves", async () => {
    const a = await service.write("alice", { ...emptyWorkspace(), notes: [] });
    await service.write("bob", {
      ...emptyWorkspace(),
      settings: { ...emptyWorkspace().settings, name: "Bob" },
    });
    await service.write("alice", {
      ...a,
      settings: { ...a.settings, name: "Alice" },
    });
    await expect(service.write("alice", a)).rejects.toThrow(Conflict);
    expect((await service.workspace("bob")).settings.name).toBe("Bob");
  });
  it("rejects malformed data and over-size snapshots", async () => {
    expect(
      workspaceSchema.safeParse({
        ...emptyWorkspace(),
        settings: { timezone: "bad" },
      }).success,
    ).toBe(false);
    await expect(
      service.write("u", { ...emptyWorkspace(), tasks: [{ title: "oops" }] }),
    ).rejects.toThrow();
  });
  it("extracts explicit action points without guessing at prose", () => {
    expect(
      extractActions(
        "Meeting notes\n- [ ] Send proposal\n- [x] Already done\nACTION: Confirm date\nTODO: Book room\n- A thought",
      ),
    ).toEqual(["Send proposal", "Confirm date", "Book room"]);
  });
  it("counts completion in the configured timezone", () => {
    const w = emptyWorkspace();
    w.settings.timezone = "Europe/Stockholm";
    w.tasks = [
      newTask("Done", {
        status: "done",
        completedAt: "2026-10-03T23:00:00.000Z",
      }),
      newTask("Late", { due: "2026-10-03" }),
    ];
    const s = summary(w, new Date("2026-10-04T10:00:00.000Z"));
    expect(s.completed).toHaveLength(1);
    expect(s.overdue).toHaveLength(1);
  });
});
describe("reminders", () => {
  it("ignores completed, deleted, and rescheduled tasks", async () => {
    const t = newTask("Original", { remindAt: "2026-10-04T12:00:00.000Z", telegramReminder: true });
    await service.write("u", {
      ...emptyWorkspace(),
      tasks: [{ ...t, status: "done" }],
    });
    const send = vi.spyOn(service, "send");
    await service.deliver({
      user: "u",
      kind: "reminder",
      taskId: t.id,
      remindAt: t.remindAt,
    });
    await service.deliver({
      user: "u",
      kind: "reminder",
      taskId: "deleted",
      remindAt: t.remindAt,
    });
    expect(send).not.toHaveBeenCalled();
    await repo.put("WORKSPACE#u", {
      ...emptyWorkspace(),
      tasks: [{ ...t, remindAt: "2026-10-05T12:00:00.000Z" }],
    });
    await service.deliver({
      user: "u",
      kind: "reminder",
      taskId: t.id,
      remindAt: t.remindAt,
    });
    expect(send).not.toHaveBeenCalled();
  });
  it("deduplicates retries and allows retries after failed delivery", async () => {
    const t = newTask("A task", { remindAt: "2026-10-04T12:00:00.000Z", telegramReminder: true });
    await service.write("u", { ...emptyWorkspace(), tasks: [t] });
    await repo.put("BOT#" + userHash("u"), { chatId: 123 });
    const send = vi
      .spyOn(service, "send")
      .mockRejectedValueOnce(new Error("Temporary failure"))
      .mockResolvedValue();
    const event = {
      user: "u",
      kind: "reminder" as const,
      taskId: t.id,
      remindAt: t.remindAt,
    };
    await expect(service.deliver(event)).rejects.toThrow("Temporary failure");
    await service.deliver(event);
    await service.deliver(event);
    expect(send).toHaveBeenCalledTimes(2);
  });
  it("retains the exact instant in UTC and does not schedule completed tasks", () => {
    const t = newTask("Call", { remindAt: "2026-10-04T12:00:00.000Z", telegramReminder: true });
    const input = reminderSchedule(
      "u",
      t,
      new Date("2026-10-04T10:00:00.000Z").getTime(),
    );
    expect(input?.ScheduleExpression).toBe("at(2026-10-04T12:00:00)");
    expect(input?.ActionAfterCompletion).toBe("DELETE");
    expect(reminderSchedule("u", { ...t, status: "done" })).toBeNull();
  });
});
describe("Telegram trust boundary", () => {
  it("rejects other chats and group pairing", async () => {
    const hash = userHash("alice");
    await repo.put("BOT#" + hash, {
      user: "alice",
      botName: "wm",
      chatId: 123,
      pairCode: "secret",
      pairExpires: Date.now() + 10000,
    } satisfies Bot);
    const fetcher = vi.spyOn(globalThis, "fetch");
    await service.incoming(hash, {
      update_id: 1,
      message: { text: "steal this", chat: { id: 999, type: "private" } },
    });
    await service.incoming(hash, {
      update_id: 2,
      message: { text: "/start secret", chat: { id: 999, type: "group" } },
    });
    expect(await repo.get("WORKSPACE#alice")).toBeUndefined();
    expect((await repo.get<Bot>("BOT#" + hash))?.chatId).toBe(123);
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("captures one task for duplicate Telegram updates", async () => {
    const hash = userHash("alice");
    await repo.put("BOT#" + hash, {
      user: "alice",
      botName: "wm",
      chatId: 123,
      pairCode: "",
      pairExpires: 0,
    } satisfies Bot);
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      json: async () => ({ ok: true, result: {} }),
    } as Response);
    const event = {
      update_id: 5,
      message: {
        text: "Remember the report",
        chat: { id: 123, type: "private" },
      },
    };
    await service.incoming(hash, event);
    await service.incoming(hash, event);
    const w = await repo.get<Workspace>("WORKSPACE#alice");
    expect(
      w?.tasks.filter((t) => t.title === "Remember the report"),
    ).toHaveLength(1);
  });
});

it("chunks large multilingual workspaces without corrupting Unicode", () => {
  const value = { notes: "📚 Meeting notes — Stockholm\n".repeat(30000) };
  const chunks = encodeSnapshot(value);
  expect(chunks.length).toBeGreaterThan(1);
  expect(chunks.every((c) => Buffer.byteLength(c) <= 200000)).toBe(true);
  expect(decodeSnapshot(chunks)).toEqual(value);
});

it("starts with an empty workspace instead of demo data", async () => {
  const w = (await service.route(
    "fresh",
    "GET",
    "/workspace",
    undefined,
    "https://example.invalid",
  )) as Workspace;
  expect(w.tasks).toEqual([]);
  expect(w.notes).toEqual([]);
  expect(w.sample).toBe(false);
});

it("removes unchanged examples while preserving user work and modified examples", () => {
  const original = sampleWorkspace();
  const clean = withoutStarterContent(original);
  expect(clean.tasks).toHaveLength(0);
  expect(clean.notes).toHaveLength(0);
  const edited = sampleWorkspace();
  edited.notes[0].body += "\nMy own meeting notes";
  edited.tasks[0].remindAt = new Date(Date.now() + 3600000).toISOString();
  edited.tasks.push(newTask("My own next action"));
  edited.strokes = [
    {
      id: "drawing",
      points: [
        [1, 2],
        [3, 4],
      ],
    },
  ];
  const kept = withoutStarterContent(edited);
  expect(kept.notes).toHaveLength(1);
  expect(kept.tasks).toHaveLength(2);
  expect(kept.strokes).toEqual(edited.strokes);
  expect(kept.nodes).toEqual(edited.nodes);
  expect(kept.tasks[0].noteId).toBe(edited.notes[0].id);
});

describe("task priorities and daily brief preferences", () => {
  it("loads old normal priorities as medium and defaults briefs to all priorities", () => {
    const w = emptyWorkspace();
    const legacy = {
      ...w,
      tasks: [{ ...newTask("Old action"), priority: "normal" }],
      settings: { ...w.settings, digestPriorities: undefined },
    };
    const normalized = workspaceSchema.parse(legacy);
    expect(normalized.tasks[0].priority).toBe("medium");
    expect(normalized.settings.digestPriorities).toEqual([
      "low",
      "medium",
      "high",
      "urgent",
    ]);
  });
  it("includes only selected open priorities, sorted urgent first", () => {
    const w = emptyWorkspace();
    w.settings.digestPriorities = ["high", "urgent"];
    w.tasks = [
      newTask("Low secret", { priority: "low", due: "2026-01-01" }),
      newTask("Medium secret", { priority: "medium" }),
      newTask("High action", { priority: "high" }),
      newTask("Urgent action", { priority: "urgent" }),
      newTask("Finished urgent", { priority: "urgent", status: "done" }),
    ];
    expect(dailyBriefTasks(w).map((t) => t.title)).toEqual([
      "Urgent action",
      "High action",
    ]);
    const text = digest(w, new Date("2026-10-04T12:00:00Z"));
    expect(text).toContain("2 open actions");
    expect(text).not.toContain("secret");
    expect(text).not.toContain("Finished urgent");
    expect(text.indexOf("Urgent action")).toBeLessThan(
      text.indexOf("High action"),
    );
  });
  it("uses the newly selected priorities for manual sending before autosave completes", async () => {
    const w = emptyWorkspace();
    w.tasks = [
      newTask("Low excluded", { priority: "low" }),
      newTask("Urgent included", { priority: "urgent" }),
    ];
    await service.write("u", w);
    const send = vi.spyOn(service, "send").mockResolvedValue();
    await service.route(
      "u",
      "POST",
      "/telegram/test",
      { kind: "digest", priorities: ["urgent"] },
      "https://example.invalid",
    );
    expect(send.mock.calls[0][1]).toContain("Urgent included");
    expect(send.mock.calls[0][1]).not.toContain("Low excluded");
  });
  it("uses the saved priorities for scheduled briefs", async () => {
    const w = emptyWorkspace();
    w.settings.digestEnabled = true;
    w.settings.digestPriorities = ["high"];
    w.tasks = [
      newTask("High included", { priority: "high" }),
      newTask("Urgent excluded", { priority: "urgent" }),
    ];
    await service.write("u", w);
    await repo.put("BOT#" + userHash("u"), { chatId: 123 });
    const send = vi.spyOn(service, "send").mockResolvedValue();
    await service.deliver({ user: "u", kind: "digest", date: "2026-10-04" });
    expect(send.mock.calls[0][1]).toContain("High included");
    expect(send.mock.calls[0][1]).not.toContain("Urgent excluded");
  });
  it("requires at least one valid priority and handles an empty matching list", () => {
    const w = emptyWorkspace();
    w.settings.digestPriorities = ["urgent"];
    expect(digest(w)).toContain("No open actions with these priorities.");
    expect(
      workspaceSchema.safeParse({
        ...w,
        settings: { ...w.settings, digestPriorities: [] },
      }).success,
    ).toBe(false);
  });
});
