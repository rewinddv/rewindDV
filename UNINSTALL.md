# Remove rewindDV and restore security

1. Finish capture and verification, stop tape motion, quit rewindDV and disconnect
   FireWire. Preserve original captures and any reports you need.
2. With SIP still disabled, inspect the registered extension:

   ```sh
   systemextensionsctl list | grep -F 'net.rewinddigital.RewindDV.Driver'
   ```

   The ad-hoc team identifier is `-`. If a different identity appears, stop and
   contact info@rewinddv.com. Do not substitute another team or vendor. If no
   entry is present, skip uninstall. Otherwise run:

   ```sh
   sudo systemextensionsctl uninstall - net.rewinddigital.RewindDV.Driver
   ```

   Restart when requested or when marked `terminated waiting for uninstall on
   reboot`. Check the list again. No output means no registered rewindDV
   extension was listed. Never use `systemextensionsctl reset` or manually
   delete `/Library/SystemExtensions`.
3. Once the extension is absent, move **/Applications/RewindDV.app** to Trash
   in Finder. Deleting the app alone does not prove its driver was removed.
4. Turn off development mode:

   ```sh
   sudo systemextensionsctl developer off
   ```

5. Shut down. Hold power to startup options, select **Options → Continue**, then
   **Utilities → Terminal**. Run `csrutil enable` and restart normally. If you
   independently changed Startup Security policy, restore the original policy
   using Startup Security Utility.
6. Verify:

   ```sh
   csrutil status
   systemextensionsctl list | grep -F 'net.rewinddigital.RewindDV.Driver'
   test ! -e '/Applications/RewindDV.app' && echo 'rewindDV app removed'
   ```

   Expect SIP enabled, no rewindDV extension entry and the app-removed message.
   Do not attempt to run this ad-hoc driver with SIP restored.

Capture folders remain at the locations you selected. These removal steps do
not delete captures or app reports. Do not remove parent Library directories,
other vendors' drivers or unrelated files.

For rollback, complete driver removal first, then use a separately retained,
verified previous package and its instructions. Never use a withdrawn download
as an assumed supported rollback. This release includes no prior binary.

If the Mac cannot start normally, disconnect FireWire and try Safe Mode: hold
power to startup options, select the startup disk, hold Shift and choose
**Continue in Safe Mode**. Remove only rewindDV as above. Do not experiment
with boot arguments or erase storage.
