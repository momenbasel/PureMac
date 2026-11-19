# Apple feature and storage research

Checked 2026-10-24 against Apple documentation. These are supported user workflows, not proof of a public API for changing the setting or of a setting's state on a particular Mac.

## Consumer controls

| Feature | Supported route | Boundary |
|---|---|---|
| Apple Intelligence | On macOS 15/26, System Settings > Apple Intelligence & Siri > Apple Intelligence. | Version-specific guide confirms off switch. Do not promise immediate model removal or a fixed number of GB. |
| Siri | System Settings > Apple Intelligence & Siri (or Siri), then switch Siri off. | Independent of Apple Intelligence, Dictation, and Siri history. Current macOS 27 guide uses Turn Off Siri. |
| Image Playground and Genmoji | Screen Time > Content & Privacy > enable restrictions > Intelligence & Siri > Image Creation off (26). | Restricts image creation; not an uninstall. Image Wand is iPhone/iPad only in this guide. |
| Writing Tools | Same Screen Time panel > Writing Tools off (26). | Restricts use; no storage savings promised. |
| ChatGPT integration | Apple Intelligence & Siri > ChatGPT > Use ChatGPT off; Setup Prompts off also prevents suggestions to configure it (26). | Screen Time > Intelligence Extensions off blocks extension access. Does not uninstall ChatGPT app. |
| Notification summaries | System Settings > Notifications > Summarize Notifications off. | Separate per-feature setting, especially relevant on 27. |
| Mail summaries | Mail > Settings > Viewing > Summarize Message Previews off. | App-owned setting; no system storage claim. |
| Inline text predictions | Keyboard > Text Input > Edit > Show inline predictive text off. | Separate from Apple Intelligence and autocorrection; language availability varies. |
| Apple analytics | Privacy & Security > Analytics & Improvements. | Review Share Mac Analytics, Improve Siri Dictation, and other sharing choices individually. |
| Personalized ads | Privacy & Security > Apple Advertising > Personalized Ads off. | Changes targeting; does not promise fewer ads. |

Sources:
- Apple Intelligence toggle, version 26: https://support.apple.com/guide/mac-help/mchl46361784/26/mac/26
- Siri settings, version 26: https://support.apple.com/guide/mac-help/mchl3fd7fc15/26/mac/26
- Screen Time restrictions, version 26: https://support.apple.com/guide/mac-help/mchlb2e44f94/26/mac/26
- ChatGPT, version 26: https://support.apple.com/guide/mac-help/mchlfc5cf131/26/mac/26
- Current per-feature controls: https://support.apple.com/guide/mac-help/mchlb2e44f94/mac
- Current Siri restrictions: https://support.apple.com/guide/mac-help/z25xrnykpuln/mac
- Inline predictions: https://support.apple.com/guide/mac-help/mchlp2299/mac
- Analytics and advertising: https://support.apple.com/guide/mac-help/mchl211c911f/27/mac/27
- Advertising details: https://support.apple.com/105131

macOS 27 reorganizes controls. Current Apple guides use System Settings > Siri > Turn Off Siri and Screen Time > Content & Privacy Restrictions > Siri > Don't Allow Siri / per-capability restrictions. Do not display 26 navigation unconditionally on 27.

Native verification on macOS 27.0.1 confirmed that Screen Time requires All Restrictions enabled before the Siri sheet controls become available. Its capabilities include Writing Assistance, Image Creation, and Extensions (including ChatGPT). The sheet states that the Siri version setting applies to the Apple Account across devices. Verification opened the panels without changing any setting.

## Model storage and protected apps

Opening https://support.apple.com/en-us/121115 currently returns the macOS 27 article. It describes system-integrated models and storage requirements; it no longer promises that turning a switch off deletes all models. Search-engine snippets still contain the older 26-era model-removal sentence. The live document wins. Do not hardcode a recoverable number, equate a disabled feature with deleted models, or delete MobileAsset/system model folders.

Apple states that macOS-required apps, including apps in /System, cannot be deleted through Finder. Ordinary downloaded apps can be moved to Trash; optional Apple apps outside protected system locations should be reviewed individually. Source: https://support.apple.com/102610

## Profiles and management

Apple's deployment table says legacy Writing Tools, Image Playground, and Genmoji restrictions (macOS 15+) require supervision: https://support.apple.com/guide/deployment/depba790e53/web

However, Apple's developer Restrictions metadata and official device-management schema do not flag those macOS keys as supervised (they do for iOS/visionOS), while the payload permits manual installation. `allowAssistant` is macOS 14+; `allowImagePlayground`, `allowGenmoji`, `allowWritingTools` are macOS 15+; `allowExternalIntelligenceIntegrations` is macOS 15.2+. All are deprecated from macOS 26.4. Sources:
- https://developer.apple.com/documentation/devicemanagement/restrictions
- https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.applicationaccess.yaml

Therefore do not claim every legacy profile is MDM-only, but also do not claim a manually installed profile enforces these controls without testing the target OS. New declarative Apple Intelligence configuration requires macOS 26.4+, supervision, and Device Enrollment or Automated Device Enrollment: https://support.apple.com/guide/deployment/apple-intelligence-declarative-configuration-dep9520d6032/web

No documented consumer API for changing or reliably reading these switches was established by this review. Hidden defaults writes, launchctl unloads, killing daemons, or installing a profile are not proof that the effective feature is disabled. Settings guidance is supported today; automatic changes need separate effective-state verification.

## Real optional storage

| Content | Apple-supported management | Product implication |
|---|---|---|
| GarageBand/Logic/MainStage sound content | General > Storage > Music Creation | Review in Storage; shared sound libraries can be used by more than one app. |
| Local iPhone/iPad backups | Finder device > General > Manage Backups; files at ~/Library/Application Support/MobileSync/Backup/ | User data, never generic junk or automatic selection. |
| Downloaded music/TV/books/podcasts | Corresponding Storage category or owning app | Remove local downloads through the app; do not conflate with deleting library/iCloud items. |
| Downloaded speech voices | Accessibility > Read & Speak > System voice info; swipe a downloaded voice left and delete | Use settings; preserve accessibility functionality and shared assets. |
| Xcode optional components/runtimes | Xcode > Settings > Components > info > Delete or Turn Off | Xcode owns supported component removal and reports recoverable size. |

Sources:
- https://support.apple.com/guide/mac-help/mchl3d437fbc/mac
- https://support.apple.com/108809
- https://support.apple.com/guide/mac-help/mchlp2290/mac
- https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components

No Apple-supported direct filesystem deletion workflow for downloaded aerial screen saver assets was established. An inventory can report their allocated storage with explicit access/measurement limits; do not promise cleanup or savings simply because the directory exists.

## Implemented boundaries

The Apple Features page opens settings and explains the remaining manual steps. It does not write undocumented preferences, install profiles, stop system services, infer enabled state from files, or remove protected apps. Version checks only determine whether to offer a settings shortcut; model, language, region, and management restrictions still affect availability.

Apple Storage measures allocated blocks in five known locations. Hard links are counted once per location. Symbolic links and cloud-only items are skipped, inaccessible entries and entry limits produce partial results, and absent locations are distinct from measured zero. Compiled model/resource packages are traversed only in the model inventory. No inventory result enters ordinary cleanup or scheduled cleaning.

Device backup removal is a separate user-level Trash workflow. It requires local regular Info.plist, Manifest.plist, Manifest.db and Status.plist files and a finished SnapshotState, then checks the full directory metadata again before removal. Legacy or incomplete backup formats remain available through Finder. Selections start empty, exclusions apply, and changed folders, symbolic links and scans exceeding 500,000 entries or 128 levels are refused. Navigating away cancels remaining work and preserves the partial result for review. FileManager's final Trash call is path-based, so a race remains after the last validation. No administrator or permanent-delete fallback exists. Space is retained until the Trash is emptied.

## Manual validation before claiming a change

1. Record macOS version and architecture; check feature availability in System Settings. Intel Macs and older macOS versions must not present unavailable Apple Intelligence controls as enabled.
2. Open each PureMac settings action and confirm the intended pane opens. If a deep link fails, show the manual route. Opening Settings must not mark the feature disabled.
3. On a disposable test account, change one supported setting, reopen the corresponding Apple UI, and check the affected behavior. Test Siri separately from Apple Intelligence, image creation, Writing Tools, extensions, and summaries. Restore the previous choice after testing.
4. For storage inventory, test an absent directory, unreadable directory, symlink, empty directory, and cancelled scan. Unknown/partial results must remain distinguishable from zero usage. Do not add review-only content to cleanup selections or scheduled cleaning.
5. Confirm system apps and OS-owned models cannot enter removal, ordinary Apple app removal uses an explicit review, and no SIP change or profile installation occurs as a side effect.
6. Recheck the feature on each supported OS version after Apple updates. A preference value or completed shell command alone does not establish that a restriction is effective.
