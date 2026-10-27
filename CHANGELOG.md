# Changelog

All notable changes to Brim are recorded here. Versions follow
[semantic versioning](https://semver.org).

## [1.1] - 2026-10-27

- Load removal previews in the background and reuse scans when selections change.
- Fix false scan timeouts in deep application folders and recognize wrapped apps.
- Keep scan details out of the removal list and load additional rows on demand.
- Select optional removal items by subgroup, with clearly attributed cache
  folders and crash reports selected after a complete search. Category buttons
  stay available while other selections update.
- Include companion launchers and their files when their executable links
  into the app being removed. Broken executable wrappers no longer keep
  files out of removal as though the wrapper were still usable.
- Remove the app's exact Dock shortcut after its bundle is gone.
- Show native pointer feedback over clickable controls, selectable text and
  ordinary space, with an arrow over disabled actions.

## [1.0] - 2026-10-17

The first release.

- Remnants finds files, settings and background jobs left by apps you have
  already removed, and says how Brim knows who each one belonged to.
- Apps removes an app together with the files it keeps elsewhere, in one
  review, and leaves anything another installed app still uses.
- Background lists login items and launch jobs, including those pointing at
  software that is gone.
- Updates installs a new version only when the same developer signed it.
- Installers can be opened in Brim to see what they would add before
  anything changes.
- Journal records every removal and checks again that it stayed removed.
- Space, Developer and Energy show where storage goes, which build caches
  can be cleared and which apps use power.

[1.1]: https://github.com/sabharishhh/brim/releases/tag/v1.1
[1.0]: https://github.com/sabharishhh/brim/releases/tag/v1.0
