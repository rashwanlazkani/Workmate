import { expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { noteSchema } from "../src/model";
it("preserves sections in backups and accepts existing notes", () => {
  const old = { id: randomUUID(), title: "Meetings", body: "Agenda", project: "", updatedAt: new Date().toISOString(), pinned: false };
  expect(noteSchema.parse(old).sections).toBeUndefined();
  const sections = [{ id: randomUUID(), title: "Meetings", body: "Agenda", richText: "rtf" }, { id: randomUUID(), title: "Decisions", body: "Release", meetingIds: [randomUUID()] }];
  expect(noteSchema.parse({ ...old, sections }).sections).toEqual(sections);
  expect(noteSchema.safeParse({ ...old, sections: [sections[0], sections[0]] }).success).toBe(false);
});
