# SwipeClean

A Tinder-style photo cleaner for iPhone. One photo fills the screen at a time:
**swipe left to bin it, swipe right to keep it.** Nothing is actually deleted
until you tap the red button in the bin and confirm iOS's own prompt — and even
then everything lands in **Recently Deleted** for 30 days.

## How it works

- Reads your library through **PhotoKit**. If you use iCloud Photos, your whole
  library is already synced to the phone; SwipeClean downloads full-resolution
  originals on demand, and deletions sync back to iCloud automatically.
- Remembers every photo you've judged, so closing the app and coming back later
  picks up exactly where you left off (`review-state.json` in Application Support).
- Photos you swipe left on pile up in a bin. You can review that grid and tap
  any photo to put it back before committing.
- Deleting is **batched** on purpose: one system confirmation for the whole pile
  instead of one per photo.

## Controls

| Action | Gesture |
| --- | --- |
| Keep | Swipe right, or tap the green check |
| Bin | Swipe left, or tap the red trash |
| Undo last swipe | Tap the arrow between the buttons |
| See the whole photo (uncropped) | Tap the card |
| Review the bin / delete for real | Tap the red pill at the top right |
| Sort order, rescan, start over | Tap the `⋯` menu |

## Getting it onto your phone

1. Open `SwipeClean.xcodeproj` in Xcode.
2. The iOS 26.5 platform and simulator runtime are already installed on this Mac,
   so Xcode shouldn't ask for anything.
3. Select the **SwipeClean** target → **Signing & Capabilities** → set **Team**
   to your own Apple ID. (Xcode → Settings → Accounts to add it if it's not there.)
   Free Apple IDs work fine; the app just needs re-signing every 7 days.
4. If Xcode complains the bundle identifier is taken, change
   `com.aadi.SwipeClean` to something unique.
5. Plug in your iPhone, pick it from the device menu at the top, and press ⌘R.
6. First launch on the phone: **Settings → General → VPN & Device Management →**
   trust your developer certificate.
7. Grant **Full Access** when it asks for photos. Limited access only shows the
   handful of photos you picked, which defeats the point.

## Notes

- Videos are included too, shown as a still with their duration.
- The size next to each photo and on the delete button is the real on-disk size,
  so you can see how much space a cleanup session actually frees.
- Requires iOS 17 or later.
