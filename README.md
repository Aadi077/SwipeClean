# SwipeClean

A Tinder-style photo cleaner for iPhone. One photo fills the screen at a time:
**swipe left to bin it, swipe right to keep it.** Nothing is actually deleted
until you tap the red button in the bin and confirm iOS's own prompt — and even
then everything lands in **Recently Deleted** for 30 days.

## How it works

- Reads your library through **PhotoKit**. If you use iCloud Photos, your whole
  library is already synced to the phone; SwipeClean downloads full-resolution
  originals on demand, and deletions sync back to iCloud automatically.
- **Wi-Fi only by default.** iCloud originals aren't pulled over cellular
  unless you say so — per photo, or permanently from the `⋯` menu. Downloads
  show progress rather than looking frozen.
- Remembers every photo you've judged, so closing the app and coming back later
  picks up exactly where you left off (`review-state.json` in Application Support).
- **Filters stack.** Type (screenshots, videos, selfies, Live Photos,
  favourites), album, and month combine — "Screenshots from Sept 2024" is one
  filter. Counts are faceted, so picking Videos rewrites the month list to show
  video counts per month and hides months with none. Empty slices don't appear
  at all. The filter persists across launches, and "Start over" applies to just
  what's filtered.
- **Biggest first.** Sizes are measured once in the background and cached, so
  you can aim at the forty videos that outweigh four thousand photos.
- **Swipe up to skip.** Defers the ones you can't decide on to a pile that
  survives relaunch, instead of forcing a keep-or-bin call on every photo.
- **Find duplicates.** Groups bursts and repeat shots, pre-picks the biggest
  copy to keep, and sends the rest to the bin. Candidates are clustered by
  capture time first, so it never analyses your whole library.
- **Videos play** on the card, muted and looping, rather than sitting frozen.
- **A receipt** after each delete, plus session and all-time totals under
  "Your progress" — otherwise the reclaimed space never shows up anywhere.
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
| Skip / decide later | Swipe up, or tap the grey arrow |
| Play or pause a video | Tap the card |
| Filter by type, album or month | Tap the filter icon at the top |
| Duplicates, progress, sort, cellular | Tap the `⋯` menu |

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

- Duplicate detection needs a real device: the iOS Simulator can't create the
  Vision feature extractor's context, and the app says so rather than claiming
  it found nothing.
- The size next to each photo and on the delete button is the real on-disk size,
  so you can see how much space a cleanup session actually frees.
- Requires iOS 17 or later.
