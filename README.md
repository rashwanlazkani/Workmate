# Workmate for Mac

Workmate is a native **SwiftUI + AppKit** macOS app. The client is entirely Swift, with no web view, JavaScript runtime, or local server. Node is only needed if you maintain the optional AWS backend.

## Open and build

Open `Workmate.app`, or open `Package.swift` in Xcode to work on the source. From this folder:

```sh
zsh Scripts/build.sh
zsh Scripts/test.sh
```

The build script publishes one `Workmate.app` here. Builds use a stable Apple Development signing identity so macOS can retain Documents/calendar approvals across updates. Set `WORKMATE_SIGNING_IDENTITY` to your own valid signing identity when building on another Mac; the script intentionally does not silently fall back to ad-hoc signing. Switching from earlier ad-hoc builds may require one final macOS approval. Intermediate build products stay in macOS's temporary directory. The test script includes the Swift Testing plugin workaround needed by some Command Line Tools installations. No third-party Swift packages are required. The app requires macOS 14 or later; Apple Intelligence features require a supported Mac and macOS 26 or later.

## Project layout

- `Sources/Workmate/` — native interface, calendars, notifications, and on-device AI.
- `Sources/WorkmateCore/` — workspace models, storage, search, and cloud client.
- `Tests/` — Swift tests.
- `Resources/` — app metadata, icon, and cloud configuration.
- `Scripts/` — native build, test, and icon tools.
- `Agent/` — Raspberry Pi reminder service, Docker Compose, and tests. See `Agent/README.md`.
- `Cloud/` — optional AWS backend source and deployment tools. See `Cloud/README.md`.

## Working with notes and meetings

The interface uses a charcoal `#1F1F24` background, white text, and `#5482FF` blue accents, with consistent glass buttons and anchored native SwiftUI popovers.

Write in side-by-side note columns. Each note has a compact native formatting toolbar for bold (⌘B), italic (⌘I), bullets, numbered lists, clickable checklists and links (⌘K). Return continues a list; Return on an empty item ends it. Formatting is saved with the note in iCloud and AWS backups, alongside plain text for search and AI. Add tasks inline and choose Low, Medium, High, or Urgent priority. Reminder controls offer quick presets and native calendar/time controls. Open a task to add lowercase tags. Existing meeting names and reused tags are suggested; click a saved tag to search. Tags matching a meeting name also include the task in that meeting’s focused view. There is no task due-date field. Completing a task moves it into Archive; uncheck it to restore it.

The calendar control is always visible. Open it to create a meeting, search all existing meetings, or filter to one meeting’s notes and actions. Choose **One-time** for a dated meeting or **Recurring** for any combination of weekdays, with separate start/end times for each selected day. Reminders default to ten minutes before. Connect selected macOS calendars in Settings to include events from accounts already configured in Calendar. Workmate reads those calendars without editing their events. Clicking a meeting notification or the current meeting in the toolbar opens its related notes and actions. Use **Meeting** beneath a note to link an existing meeting or create another. A newly created meeting links to that note automatically. Linked meetings appear as clickable metadata tags above the note title.

Search with **⌘F** for notes, tasks, and meetings, including items linked through meeting metadata. Tick **Include archive** to include completed tasks. Use **⌘N** for a new note and **⌘,** for Settings. Text-entry views focus their first editable field when opened. Closing the red window button leaves the app running; its Dock icon or **⌘0** brings the workspace back.

Optional Apple Foundation Models intelligence scans notes on this Mac to suggest meeting links, summaries, and action points. Suggestions need your review and never overwrite note text. Manual linking and search work without Apple Intelligence.

## Your data

Workmate uses the current Mac user's iCloud Drive. Its main folder is **iCloud Drive → Documents → Workmate**:

- `workspace.json` — readable notes, tasks, meeting links, archive, priorities and reminder settings.
- `config.json` — portable preferences and the private, workspace-scoped AWS connection key.
- `insights-local.json` — on-device AI suggestions.
- `Recovery/` — migration copies and preserved conflicting edits.

Settings → **Show files in Finder** opens the exact folder. There is no Workmate sign-in. macOS handles iCloud uploads and downloads using your existing Apple Account. The app reports that a file was saved in iCloud Drive, not that Apple's upload has finished. If iCloud Drive is unavailable at first launch, files are saved in local `Documents/Workmate`; configure iCloud Drive and move the folder there before reopening Workmate to switch locations.

Existing native data is migrated automatically on first launch, without replacing an existing iCloud workspace or deleting the previous files in `~/Library/Application Support/Workmate`. The earlier browser data and backups remain there too. The app coordinates file reads/writes with macOS, checks for changes from other devices, and merges independent edits. Conflicting versions are preserved in Recovery, with an in-app notice. Export/import accepts the readable workspace JSON.

## AWS backup and Telegram

The private connection lives in the Workmate folder, so another Mac using the same iCloud Drive can use it without a new account. **Keep config.json private**: its key grants access to this workspace's AWS copy and Telegram connection. It contains no AWS administrator credentials and is never bundled in the application or project.

AWS **eu-north-1 (Stockholm)** keeps immutable, encrypted S3 snapshots and a DynamoDB copy for reminder scheduling and Telegram updates. iCloud files remain the main workspace. S3 has versioning and blocks public access. Backup failures leave local edits intact and retry while the app runs. Settings shows backup status and has **Back up now**. Pausing backup stops future uploads; reminders already scheduled in AWS may still arrive.

Under **Settings → Telegram**, open BotFather, send `/newbot`, paste its token, connect, then open the pairing link and tap Start. Bot tokens are held in AWS Secrets Manager and excluded from workspace backups. Each action's reminder offers **Also notify in Telegram**. Mac notifications are always included, subject to macOS notification permission. Choose which priorities to send under **Daily brief**.

The Raspberry Pi reminder agent receives schedule changes over a persistent MQTT connection and uses durable local timers to deliver opted-in task reminders, meeting reminders and daily briefs while Workmate is closed. It does not poll the plan on a fixed interval. Telegram reminders have **Mark complete** and **Snooze 1 hour** buttons with visible confirmation. Native Mac reminders offer the same actions. The Pi needs power and network access; edits must sync before closing the app. Task and daily brief schedules in AWS remain a fallback, using shared delivery receipts. See `Agent/README.md` for deployment and delivery boundaries. Meeting focus notifications use macOS. Imported calendars refresh while Workmate runs. On first use, connect calendars in Settings; to add another account, choose **Calendar → Add Account** in Apple's Calendar app.

## Help and first launch

A four-step welcome tour appears on first launch and can be skipped. Open **Help → Workmate Help**, the toolbar **?**, or **Settings → Help & getting started** for searchable topics. Choose **Welcome Tour…** or **Restart tour** to replay it. Tutorial completion is remembered on this Mac. Popups remain open when you switch apps. Press Escape to close the active popup, including from a text or time field. You can also close it explicitly, or finish with Save, Cancel or a selection.

Notes can contain stacked sections in one column. Use **Add section** for a new heading, or the section icon beside the formatting toolbar → **Split at cursor** to move the text below the cursor into a new section. **Merge with section above** keeps both sections’ text and formatting. Sections remain part of the same searchable note and iCloud/AWS backup.

Each note section has its own **Meeting** selector and removable meeting tags. Meeting focus shows only that meeting’s sections; search includes section meeting links. Existing note-level links move to the original first section. Splitting keeps the tags on both parts; merging retains both sections’ links.

For notes with multiple sections, the large title at the top names the whole column independently; each section has its own heading. Formatting controls use larger icons, 17-point body text and larger list markers.

Use the section menu → **Delete section…** to remove a section after confirmation. The column name and other sections stay saved; deleting the final section leaves an empty editor.
