# GitHub description change - READY TO APPLY, NOT APPLIED

Current GitHub description (stale): says tested 2300 MHz clock cap.
Target: DGX Spark (GB10) operations toolkit - 2200 MHz clock cap standard, power-delivery research, DGX OS 7.6 headless mode, quad-stack and MikroTik setup.

Why not applied: the description is repository metadata on GitHub.com, not a file in this repo, so a local commit cannot change it. Applying it requires GitHub sign-in on AREO (or the Muse VM) plus the operators separate push approval, neither done.

Apply after sign-in, from a signed-in checkout:
  gh repo edit <owner>/gb10-ops --description "DGX Spark (GB10) operations toolkit - 2200 MHz clock cap standard, power-delivery research, DGX OS 7.6 headless mode, quad-stack and MikroTik setup."
Or edit it in the repo Settings page on GitHub.com.
No push of the local reformat has been made.
