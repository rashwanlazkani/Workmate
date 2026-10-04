import { createHash, timingSafeEqual } from "node:crypto";
import type { Repository } from "./repository";
import type { Service } from "./service";

export type DeviceAccess = { tokenHash: string; user: string; enabled: boolean };

// Keys are provisioned by the AWS owner, never through a public registration endpoint.
export async function deviceIdentity(repo: Repository, authorization = "") {
  const match = /^Bearer (wm_([a-f0-9-]{36})\.[a-f0-9]{64})$/.exec(authorization);
  if (!match) return undefined;
  const access = await repo.get<DeviceAccess>("DEVICE#" + match[2]);
  if (!access?.enabled || access.user !== "drive-" + match[2]) return undefined;
  const expected = Buffer.from(access.tokenHash, "hex");
  const actual = createHash("sha256").update(match[1]).digest();
  return expected.length === actual.length && timingSafeEqual(expected, actual) ? access.user : undefined;
}

export async function deviceRoute(service: Service, user: string, method: string, path: string, data: unknown, baseURL: string) {
  if (!((path === "/workspace" && ["GET", "PUT"].includes(method)) ||
    (path === "/telegram/status" && method === "GET") ||
    (["/telegram/connect", "/telegram/disconnect", "/telegram/test"].includes(path) && method === "POST"))) {
    throw Object.assign(new Error("Route not found"), { status: 404 });
  }
  return service.route(user, method, path, data, baseURL);
}
