import { afterEach, expect, it, vi } from "vitest";
import { IoTDataPlaneClient, PublishCommand } from "@aws-sdk/client-iot-data-plane";
import { marshall } from "@aws-sdk/util-dynamodb";
import type { DynamoDBStreamEvent } from "aws-lambda";
import { planner } from "../server/scheduler";
import { changeTopic } from "../server/push";
import { emptyWorkspace, newTask, workspaceSchema } from "../src/model";
import { notificationPlan } from "../server/notifications";

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); });
function stream(before: string, after: string) {
  const w = emptyWorkspace();
  return { Records: [{ eventID: "change", dynamodb: { SequenceNumber: "sequence-1",
    OldImage: marshall({ pk: "WORKSPACE#private-workspace", value: { ...w, notificationFingerprint: before } }),
    NewImage: marshall({ pk: "WORKSPACE#private-workspace", value: { ...w, revision: 42, notificationFingerprint: after } }),
  } }] } as unknown as DynamoDBStreamEvent;
}
it("pushes a metadata-only message for a schedule change, not an ordinary note edit", async () => {
  vi.stubEnv("IOT_DATA_ENDPOINT", "example.iot.eu-north-1.amazonaws.com");
  const send = vi.spyOn(IoTDataPlaneClient.prototype, "send").mockResolvedValue({} as never);
  expect(await planner(stream("old", "new"))).toEqual({ batchItemFailures: [] });
  expect(send).toHaveBeenCalledTimes(1);
  const command = send.mock.calls[0][0] as PublishCommand;
  expect(command.input.topic).toBe(changeTopic("private-workspace"));
  expect(command.input.qos).toBe(1);
  expect(JSON.parse(Buffer.from(command.input.payload as Uint8Array).toString())).toEqual({ kind: "schedule.changed", revision: 42 });
  await planner(stream("same", "same"));
  expect(send).toHaveBeenCalledTimes(1);
});
it("retries a stream event if push publication fails", async () => {
  vi.stubEnv("IOT_DATA_ENDPOINT", "example.iot.eu-north-1.amazonaws.com");
  vi.spyOn(IoTDataPlaneClient.prototype, "send").mockRejectedValue(new Error("offline"));
  expect(await planner(stream("old", "new"))).toEqual({ batchItemFailures: [{ itemIdentifier: "sequence-1" }] });
});
it("includes distant one-time and future recurring reminders without periodic discovery", () => {
  const w = workspaceSchema.parse({ ...emptyWorkspace(),
    tasks: [newTask("Far future", { remindAt: "2027-01-04T10:00:00Z", telegramReminder: true })],
    meetings: [{ id: "01234567-89ab-4cde-abcd-0123456789ab", title: "Future weekly",
      startAt: "2027-01-04T08:00:00Z", endAt: "2027-01-04T09:00:00Z", timezone: "Europe/Stockholm",
      recurrence: "weekly", reminderMinutes: 10, reminderEnabled: true, canceled: false,
      calendarEventId: "", calendarId: "", calendarName: "", location: "" }],
  });
  const jobs = notificationPlan(w, Date.parse("2026-10-04T12:00:00Z"));
  expect(jobs.some(j => j.taskId === w.tasks[0].id)).toBe(true);
  expect(jobs.find(j => j.kind === "meeting")?.startAt).toBe("2027-01-04T08:00:00Z");
  const afterFirst = notificationPlan(w, Date.parse("2027-01-04T09:00:00Z"));
  expect(afterFirst.find(j => j.kind === "meeting")?.startAt).toBe("2027-01-11T08:00:00Z");
});
