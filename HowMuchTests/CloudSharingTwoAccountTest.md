# Required two-account system sharing test

Run this test before release on two devices signed into different iCloud
accounts. Unit tests cannot reproduce `UICloudSharingControllerDelegate`
timing or CloudKit's removal of a share.

1. Account A creates and shares a populated family ledger with Account B.
2. As Account A, open **Manage Sharing** and stop sharing in the system sheet.
   Verify the delegate bridge shows retention progress, selects one complete
   private copy, and removes the original shared-zone graph. Repeat/retry after
   an interrupted purge and verify no second retained copy is created.
3. Repeat as Account B using the system sheet. Verify only B's shared copy is
   removed and no private copy is created.
4. Delay or interrupt sync around the stop callback. If the source graph has
   already disappeared, verify a visible error is shown and no empty ledger is
   created; restore connectivity and use Retry while the screen retains the
   known share/zone.
5. Change a participant permission without stopping sharing. Verify the
   system sheet's save callback reloads participants and access controls.
