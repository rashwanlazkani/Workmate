import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import type { Repository } from "./repository";
import type { Service } from "./service";
import { notificationPlan } from "./notifications";
export type AgentAccess = { user: string; enabled: boolean; tokenHash: string };
export async function agentIdentity(repo: Repository, authorization = "") {
  const match = /^Bearer (wma_([a-f0-9-]{36})\.[a-f0-9]{64})$/.exec(authorization);
  if (!match) return undefined;
  const access = await repo.get<AgentAccess>("AGENT#" + match[2]);
  if (!access?.enabled || !/^drive-[a-f0-9-]{36}$/.test(access.user)) return undefined;
  const expected = Buffer.from(access.tokenHash, "hex"), actual = createHash("sha256").update(match[1]).digest();
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return undefined;
  return access.user;
}
export async function agentRoute(service: Service, user: string, method: string, path: string, data: unknown, now = Date.now()) {
  if (method === "GET" && path === "/plan") {
    const w = await service.workspace(user);
    await service.repo.put("AGENT_STATUS#" + user, { lastSeen: new Date(now).toISOString() });
    // The Pi receives identifiers and timing, never notes, task text, or the Telegram token.
    return { jobs: notificationPlan(w, now), serverTime: new Date(now).toISOString(), revision: w.revision };
  }
  if (method === "POST" && path === "/deliver") {
    const { id } = z.object({ id: z.string().regex(/^[a-f0-9]{64}$/) }).parse(data);
    const w = await service.workspace(user);
    const job = notificationPlan(w, now).find(j => j.id === id);
    if (!job) return { status: "canceled" };
    if (Date.parse(job.fireAt) > now) return { status: "pending" };
    return { status: await service.deliver({ ...job, user }) };
  }
  throw Object.assign(new Error("Route not found"), { status: 404 });
}
