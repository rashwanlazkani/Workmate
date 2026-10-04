import { afterEach, expect, it, vi } from "vitest";
import { createHash } from "node:crypto";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { deviceIdentity, deviceRoute } from "../server/device";
import { emptyWorkspace, newTask } from "../src/model";
import type { Repository } from "../server/repository";
import { Service } from "../server/service";

const id = "01234567-89ab-4cde-abcd-0123456789ab";
const token = `wm_${id}.${"a".repeat(64)}`;
function repository(): Repository {
  return { async get<T>() { return { enabled: true, user: "drive-" + id, tokenHash: createHash("sha256").update(token).digest("hex") } as T; }, async put() {}, async delete() {}, async claim() { return true; } };
}
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); });
it("requires an exact private key and binds it to one workspace", async () => {
  const repo = repository();
  expect(await deviceIdentity(repo, `Bearer ${token}`)).toBe("drive-" + id);
  expect(await deviceIdentity(repo)).toBeUndefined();
  expect(await deviceIdentity(repo, `Bearer ${token.slice(0, -1)}b`)).toBeUndefined();
  expect(await deviceIdentity(repo, `Bearer ${token.replace(id, "11234567-89ab-4cde-abcd-0123456789ab")}`)).toBeUndefined();
  repo.get = async <T>() => ({ enabled: false } as T);
  expect(await deviceIdentity(repo, `Bearer ${token}`)).toBeUndefined();
});
it("backs up before scheduling and never includes the connection key", async () => {
  vi.stubEnv("BACKUP_BUCKET", "test-backups");
  const order: string[] = [];
  const send = vi.spyOn(S3Client.prototype, "send").mockImplementation(async () => { order.push("backup"); return {} as never; });
  const service = new Service(repository(), { async get() { return undefined; }, async set() {}, async delete() {} }, "cloud");
  vi.spyOn(service.repo, "put").mockImplementation(async () => { order.push("commit"); });
  const workspace = { ...emptyWorkspace(), tasks: [newTask("Agenda", { telegramReminder: true })] };
  await deviceRoute(service, "drive-" + id, "PUT", "/workspace", workspace, "https://example.com");
  expect(order).toEqual(["backup", "commit"]);
  const command = send.mock.calls[0][0] as PutObjectCommand;
  expect(command.input.Key).toMatch(new RegExp(`^workspaces/${id}/snapshots/`));
  expect(JSON.parse(command.input.Body as string).tasks[0].telegramReminder).toBe(true);
  expect(command.input.Body).not.toContain(token);
  send.mockRejectedValueOnce(new Error("S3 unavailable") as never);
  await expect(deviceRoute(service, "drive-" + id, "PUT", "/workspace", workspace, "https://example.com")).rejects.toThrow("S3 unavailable");
  expect(service.repo.put).toHaveBeenCalledTimes(1);
});
it("rejects webhook and arbitrary paths on the device API", async () => {
  await expect(deviceRoute({} as Service, "drive-" + id, "POST", "/telegram/webhook/hash", {}, "https://example.com")).rejects.toThrow("Route not found");
});
