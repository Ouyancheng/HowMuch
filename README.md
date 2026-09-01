# HowMuch

HowMuch is a personal and household spend tracker for **iPhone** and **Mac**. Record what you spent, what the card actually charged, and see totals in each ledger’s reporting currency.

Identity is your iCloud Apple ID. Data lives in Core Data (`NSPersistentCloudKitContainer`) and can sync privately or through a shared family ledger.

## What it does

- **Personal and family ledgers** — private books for you, plus household books you can invite others to (Messages or Mail, any Apple ID — not Apple Family Sharing).
- **Dual-currency expenses** — type the spend amount and the amount charged. Useful when a card bills in a different currency than the purchase.
- **Categories and payment methods** — edit, reorder, and remove them per ledger. Cash cannot be removed.
- **Receipts** — optional photo or PDF (up to 10 MB) on an expense.
- **Activity** — searchable list; swipe, right-click, or open an expense to delete it.
- **Insights** — range totals, category chart, and spend/charged breakdowns. Foreign amounts convert into the ledger currency with built-in default rates (not live market prices).
- **Localization** — English, Simplified Chinese, and Traditional Chinese (Hong Kong).

## Requirements

- Xcode 16 or later
- iOS 18 / macOS 15
- Bundle ID `com.howmuch.app`
- CloudKit container `iCloud.com.howmuch.app` (for sync and family sharing)

Open `HowMuch.xcodeproj` and run the **HowMuch** scheme.

Debug Mac builds sign ad hoc and use sandbox-only entitlements (`HowMuch-macOS-local.entitlements`). They keep data on that Mac until you choose a Team in Xcode, enable iCloud + CloudKit, and point the Mac target at `HowMuch-macOS.entitlements`. Then run **Settings → Developer → Initialize CloudKit Schema** once.

## Tests

```bash
xcodebuild -project HowMuch.xcodeproj -scheme HowMuch \
  -destination 'platform=macOS,arch=arm64' test
```
