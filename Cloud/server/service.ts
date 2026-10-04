import { backupWorkspace } from "./backup";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import {
  digest,
  priorities,
  priorityLabel,
  emptyWorkspace,
  newTask,
  notifiesTelegram,
  withoutStarterContent,
  workspaceSchema,
  type Workspace,
} from "../src/model";
import { notificationPlan, formatTime, type NotificationJob } from "./notifications";
import { Conflict, type Repository, type Vault } from "./repository";
export type Bot = {
  user: string;
  botName: string;
  chatId?: number;
  pairCode: string;
  pairExpires: number;
  cursor?: number;
};
export type TelegramUpdate = {
  update_id: number;
  message?: { text?: string; chat: { id: number; type: string } };
  callback_query?: {
    id: string;
    data?: string;
    message?: { chat: { id: number }; message_id?: number; text?: string };
  };
};
export const userHash = (user: string) =>
  createHash("sha256").update(user).digest("hex").slice(0, 32);
export const workspaceKey = (user: string) => `WORKSPACE#${user}`;
export async function telegram(
  token: string,
  method: string,
  data: Record<string, unknown> = {},
) {
  const response = await fetch(
    `https://api.telegram.org/bot${token}/${method}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
      signal: AbortSignal.timeout(12000),
    },
  );
  const payload = (await response.json()) as {
    ok: boolean;
    result: any;
    description?: string;
  };
  if (!payload.ok)
    throw new Error(`Telegram: ${payload.description || "request failed"}`);
  return payload.result;
}
export class Service {
  constructor(
    public repo: Repository,
    public vault: Vault,
    public mode: "local" | "cloud",
    public webhookSecret = "",
  ) {}
  async workspace(user: string) {
    return workspaceSchema.parse(
      (await this.repo.get<Workspace>(workspaceKey(user))) || emptyWorkspace(),
    );
  }
  async write(user: string, data: unknown) {
    const w = workspaceSchema.parse(data);
    if (Buffer.byteLength(JSON.stringify(w)) > 4000000)
      throw new Error(
        "Workspace is over 4 MB. Export a backup and archive older notes before adding more.",
      );
    if (this.mode === "cloud" && user.startsWith("drive-") && process.env.BACKUP_BUCKET) await backupWorkspace(user, w);
    const next = { ...w, revision: w.revision + 1 };
    await this.repo.put(workspaceKey(user), next, w.revision);
    return next;
  }
  async mutate(user: string, fn: (w: Workspace) => Workspace) {
    for (let i = 0; i < 4; i++) {
      const current = await this.workspace(user);
      try {
        return await this.write(user, fn(current));
      } catch (e) {
        if (!(e instanceof Conflict) || i === 3) throw e;
      }
    }
  }
  async status(user: string) {
    const bot = await this.repo.get<Bot>("BOT#" + userHash(user));
    const delivery = await this.repo.get<{ error: string }>(
      "ERROR#" + userHash(user),
    );
    return {
      configured: !!bot,
      connected: !!bot?.chatId,
      botName: bot?.botName,
      link:
        bot && !bot.chatId && bot.pairExpires > Date.now()
          ? `https://t.me/${bot.botName}?start=${bot.pairCode}`
          : undefined,
      lastError: delivery?.error,
      agentLastSeen: (await this.repo.get<{ lastSeen: string }>("AGENT_STATUS#" + user))?.lastSeen,
    };
  }
  async connect(user: string, input: unknown, baseUrl: string) {
    const { token } = z
      .object({ token: z.string().regex(/^\d{5,20}:[A-Za-z0-9_-]{20,100}$/) })
      .parse(input);
    const me = await telegram(token, "getMe");
    const hash = userHash(user);
    const bot: Bot = {
      user,
      botName: me.username,
      pairCode: randomBytes(24).toString("hex"),
      pairExpires: Date.now() + 30 * 60 * 1000,
    };
    const old = await this.repo.get<Bot>("BOT#" + hash);
    if (old && old.botName !== bot.botName) {
      const oldToken = await this.vault.get(hash);
      if (oldToken) await telegram(oldToken, "deleteWebhook");
    }
    await this.vault.set(hash, token);
    await this.repo.put("BOT#" + hash, bot);
    if (this.mode === "cloud") {
      await telegram(token, "setWebhook", {
        url: `${baseUrl}/api/telegram/webhook/${hash}`,
        secret_token: this.webhookSecret,
        allowed_updates: ["message", "callback_query"],
        drop_pending_updates: true,
      });
    } else {
      await telegram(token, "deleteWebhook", { drop_pending_updates: true });
    }
    return this.status(user);
  }
  async disconnect(user: string) {
    const hash = userHash(user),
      token = await this.vault.get(hash);
    if (token) await telegram(token, "deleteWebhook");
    await this.repo.delete("BOT#" + hash);
    await this.vault.delete(hash);
    await this.repo.delete("ERROR#" + hash);
  }
  async send(user: string, text: string, taskId?: string) {
    const hash = userHash(user),
      bot = await this.repo.get<Bot>("BOT#" + hash),
      token = await this.vault.get(hash);
    if (!bot?.chatId || !token)
      throw new Error(
        "Connect your Telegram bot and open its link in Settings first.",
      );
    try {
      await telegram(token, "sendMessage", {
        chat_id: bot.chatId,
        text: text.slice(0, 4000),
        ...(taskId
          ? {
              reply_markup: {
                inline_keyboard: [
                  [{ text: "Mark complete", callback_data: `done:${taskId}` }, { text: "Snooze 1 hour", callback_data: `snooze:${taskId}` }],
                ],
              },
            }
          : {}),
      });
      await this.repo.delete("ERROR#" + hash);
    } catch (e) {
      await this.repo.put("ERROR#" + hash, {
        error: (e as Error).message,
        at: new Date().toISOString(),
      });
      throw e;
    }
  }
  async incoming(hash: string, update: TelegramUpdate) {
    const bot = await this.repo.get<Bot>("BOT#" + hash),
      token = await this.vault.get(hash);
    if (!bot || !token) return;
    const msg = update.message;
    const reply = (text: string) =>
      telegram(token, "sendMessage", {
        chat_id: msg?.chat.id || bot.chatId,
        text,
      });
    if (msg?.text?.startsWith("/start ")) {
      const code = msg.text.slice(7).trim();
      if (
        msg.chat.type !== "private" ||
        bot.pairExpires < Date.now() ||
        code !== bot.pairCode
      )
        return;
      await this.repo.put("BOT#" + hash, {
        ...bot,
        chatId: msg.chat.id,
        pairCode: "",
        pairExpires: 0,
      });
      await reply(
        "You’re connected to Workmate. Your reminders and daily brief will arrive here. Send any message to add a task to your inbox. Use /today for your daily brief.",
      );
      return;
    }
    const chat = msg?.chat.id || update.callback_query?.message?.chat.id;
    if (!bot.chatId || chat !== bot.chatId) return;
    // A lease suppresses concurrent webhook retries. Successful updates are retained for 7 days.
    const key = `UPDATE#${hash}#${update.update_id}`;
    if (!(await this.repo.claim(key, 90))) return;
    try {
      if (update.callback_query) {
        const callback = update.callback_query;
        const match = /^(done|snooze):([a-f0-9-]{36})$/i.exec(callback.data ?? "");
        if (!match) {
          await telegram(token, "answerCallbackQuery", { callback_query_id: callback.id, text: "This action is no longer available." });
        } else {
          const [, action, id] = match;
          // Keep a stable target across webhook retries, even if Telegram feedback fails.
          const actionKey = `ACTION#${hash}#${update.update_id}`;
          let intent = await this.repo.get<{ at: string; remindAt: string }>(actionKey);
          if (!intent) {
            intent = { at: new Date().toISOString(), remindAt: new Date(Date.now() + 3600000).toISOString() };
            await this.repo.put(actionKey, intent);
          }
          let result = "This task is no longer available.";
          let text = result;
          let completed = false;
          await this.mutate(bot.user, w => {
            const task = w.tasks.find(t => t.id === id);
            if (!task) return w;
            if (action === "done" || task.status === "done") {
              completed = true;
              result = "Completed · saved in Archive";
              text = `Completed

${task.title}

Saved in your Workmate archive.`;
              return { ...w, tasks: w.tasks.map(t => t.id === id ? { ...t, status: "done", completedAt: t.completedAt || intent!.at } : t) };
            }
            result = "Snoozed for 1 hour";
            text = `Snoozed

${task.title}

Next reminder: ${formatTime(intent!.remindAt, w.settings.timezone)}`;
            return { ...w, tasks: w.tasks.map(t => t.id === id ? { ...t, remindAt: intent!.remindAt, telegramReminder: true } : t) };
          });
          if (callback.message?.message_id) {
            try {
              await telegram(token, "editMessageText", {
                chat_id: bot.chatId, message_id: callback.message.message_id, text,
                reply_markup: { inline_keyboard: completed || result.startsWith("This task") ? [] : [[{ text: "Mark complete", callback_data: `done:${id}` }]] },
              });
            } catch (error) {
              // An old/deleted message or a no-op edit must not undo the saved action.
              console.warn("Telegram action saved; message update unavailable", { type: (error as Error).name });
            }
          }
          try { await telegram(token, "answerCallbackQuery", { callback_query_id: callback.id, text: result }); }
          catch { /* Callback answers expire; the durable action and edited message remain valid. */ }
        }
      } else if (msg?.text) {
        if (msg.text === "/today") {
          await reply(digest(await this.workspace(bot.user)));
        } else if (msg.text.startsWith("/")) {
          await reply(
            "Send a thought to capture a task. /today shows your daily brief. Complete tasks using the button on a reminder.",
          );
        } else {
          const id = createHash("sha256").update(key).digest("hex");
          const uuid = `${id.slice(0, 8)}-${id.slice(8, 12)}-4${id.slice(13, 16)}-a${id.slice(17, 20)}-${id.slice(20, 32)}`;
          await this.mutate(bot.user, (w) =>
            w.tasks.some((t) => t.id === uuid)
              ? w
              : {
                  ...w,
                  tasks: [
                    newTask(msg.text!.slice(0, 500), { id: uuid }),
                    ...w.tasks,
                  ],
                },
          );
          await reply("Captured in your Workmate inbox.");
        }
      }
      await this.repo.delete(key);
      await this.repo.claim(key, 7 * 86400);
    } catch (e) {
      await this.repo.delete(key);
      throw e;
    }
  }
  async deliver(event: {
    user: string; kind: "reminder" | "digest" | "meeting";
    taskId?: string; remindAt?: string; date?: string; meetingId?: string; startAt?: string;
  }): Promise<"delivered" | "duplicate" | "skipped" | "pending"> {
    const raw = await this.repo.get<Workspace>(workspaceKey(event.user));
    if (!raw) return "skipped";
    const w = workspaceSchema.parse(raw);
    const task = w.tasks.find(t => t.id === event.taskId);
    if (event.kind === "reminder" && (!task || task.status === "done" || !notifiesTelegram(task) || task.remindAt !== event.remindAt)) return "skipped";
    if (event.kind === "digest" && !w.settings.digestEnabled) return "skipped";
    let occurrence: NotificationJob | undefined;
    if (event.kind === "meeting") {
      occurrence = notificationPlan(w).find(j => j.kind === "meeting" && j.meetingId === event.meetingId && j.startAt === event.startAt);
      if (!occurrence) return "skipped";
      if (Date.parse(occurrence.fireAt) > Date.now()) return "pending";
    }
    const bot = await this.repo.get<Bot>("BOT#" + userHash(event.user));
    if (!bot?.chatId) return "skipped";
    const key = `DELIVERY#${userHash(event.user)}#${event.kind}#${event.taskId || event.meetingId || ""}#${event.remindAt || event.startAt || event.date}`;
    if ((await this.repo.get<{ delivered?: boolean }>(key))?.delivered) return "duplicate";
    if (!(await this.repo.claim(key, 120))) {
      const receipt = await this.repo.get<{ delivered?: boolean }>(key);
      return receipt?.delivered ? "duplicate" : "pending";
    }
    try {
      let text: string;
      if (event.kind === "digest") text = digest(w);
      else if (event.kind === "meeting") {
        const meeting = w.meetings!.find(m => m.id === event.meetingId)!;
        text = `${meeting.title} coming up\n\n${formatTime(occurrence!.startAt!, meeting.timezone)} – ${formatTime(occurrence!.endAt!, meeting.timezone).split(", ").pop()}${meeting.location ? "\n" + meeting.location : ""}\n\nOpen Workmate → ${meeting.title} for your meeting notes and actions.`;
      } else {
        text = `${task!.title}\n\n${priorityLabel[task!.priority]} priority · ${formatTime(task!.remindAt, w.settings.timezone)}${task!.project ? "\n" + task!.project : ""}`;
      }
      await this.send(event.user, text, event.kind === "reminder" ? task!.id : undefined);
      await this.repo.put(key, { delivered: true });
      return "delivered";
    } catch (e) {
      await this.repo.delete(key);
      throw e;
    }
  }
  async route(
    user: string,
    method: string,
    path: string,
    data: unknown,
    baseUrl: string,
  ) {
    if (path === "/workspace" && method === "GET") {
      const raw = await this.repo.get<Workspace>(workspaceKey(user));
      const stored = raw ? workspaceSchema.parse(raw) : undefined;
      if (stored && !stored.sample) return stored;
      try {
        return await this.write(
          user,
          stored ? withoutStarterContent(stored) : emptyWorkspace(),
        );
      } catch (e) {
        if (e instanceof Conflict) return this.workspace(user);
        throw e;
      }
    }
    if (path === "/workspace" && method === "PUT")
      return this.write(user, data);
    if (path === "/telegram/status" && method === "GET")
      return this.status(user);
    if (path === "/telegram/connect" && method === "POST")
      return this.connect(user, data, baseUrl);
    if (path === "/telegram/disconnect" && method === "POST") {
      await this.disconnect(user);
      return { ok: true };
    }
    if (path === "/telegram/test" && method === "POST") {
      const { kind, priorities: included } = z
        .object({
          kind: z.enum(["test", "digest"]),
          priorities: z.array(z.enum(priorities)).min(1).max(4).optional(),
        })
        .parse(data);
      const w = await this.workspace(user);
      await this.send(
        user,
        kind === "digest"
          ? digest({
              ...w,
              settings: {
                ...w.settings,
                digestPriorities: included || w.settings.digestPriorities,
              },
            })
          : "Workmate is connected. Task reminders, meeting reminders and daily briefs will arrive here.",
      );
      return { ok: true };
    }
    throw Object.assign(new Error("Not found"), { status: 404 });
  }
}
