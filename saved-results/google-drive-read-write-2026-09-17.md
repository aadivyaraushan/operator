# Google Drive, Docs, Sheets, Slides: read and write (2026-09-17)

What this is for: why Operator could not find the "Operator waitlist" sheet,
what was changed, and what the owner must do once for it to work.

## What went wrong
- Input: "how many sign-ups on my Operator waitlist sheet".
- Expected the sheet to be found and counted; got "no matching files".
- Step that went wrong: Operator asked Google for the `drive.file`
  permission, which only shows files Operator itself created. There was
  also no way to read inside any file, and the only write was "new text file".

## What changed
- Permission asked from Google is now full `drive` (OAuthTypes.swift). The
  app already forces a fresh Google sign-in when the saved grant lacks a
  permission it now needs.
- Reads (connections.read): `googleDriveFiles` searches names and text and
  returns id, mimeType, parents. New `googleDriveFileContent` (fileID):
  Sheet as CSV, or as rows for a range; Doc/Slides as plain text; text
  files as is; other types come back as unsupported. Cut at 200,000 chars.
- Writes (connections.write, each behind the confirmation card):
  googleSheetsUpdateCells, googleSheetsAppendRows, googleDocsAppendText,
  googleDocsReplaceText, googleSlidesReplaceText, googleSlidesAddSlide,
  googleDriveUpdateTextFile, googleDriveRenameFile, googleDriveMoveFile,
  googleDriveCreateFile (document, spreadsheet, presentation, folder).
  Code: `ios/OperatorApp/Sources/connections/services/write/GoogleWorkspaceWrites.swift`.
- The describe list for connections.read was hand-written and lacked
  fileID; it is now built from the per-operation lists, like writes.
- Model guidance updated; the staged runtime was rebuilt for it.

## Evidence
- 80 Swift tests in the touched classes pass, 117 OperatorCore tests pass,
  21 runtime JS tests pass, three standalone run.sh scripts pass.
- NOT verified against real Google yet: needs the two owner steps below.
  Request shapes were written from memory of the Google APIs, not checked
  against current docs.

## Owner steps (once)
1. Google Cloud console, the project Operator's Google sign-in uses:
   turn on "Google Sheets API", "Google Docs API", "Google Slides API"
   (Drive API is already on). Free.
2. In Operator: disconnect and reconnect Google, approve the Drive access.
   Works only while the Google project is in Testing mode, or after Google
   reviews it: full Drive is a restricted permission.

## Follow-up the same day
- Verified on the Simulator after the owner's two steps: the waitlist sheet
  was found and read ("17 unique sign-ups").
- Creating a Doc failed: the approval card closed itself after 30 seconds
  (the gateway's wait limit) and the model said "expired". Now the card
  stays until the owner taps. When the gateway's wait ends first the model
  gets AWAITING_OWNER ("still on screen, nothing written"); the owner's
  later answer is kept and handed to a repeat of the same request, once.
  Code: ForegroundAccountWriteConfirmationService.swift. Not yet tried in
  the real app.
- Same 30-second pattern still exists in WhatsApp compose and contact
  create (ForegroundWhatsAppComposeService, ForegroundContactCreateService).
