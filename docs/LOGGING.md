# Logging

All player logs go through `AppLog` (`MetalPlayerCore`). Each message is sent to:

- `os.Logger`, subsystem `com.metalplayer`
- an in-memory buffer of the last 2000 entries, used by the log viewer
- `~/Library/Application Support/MetalPlayer/player.log`, written asynchronously

Messages below `AppLog.minimumLogLevel` are not formatted (the message is an `@autoclosure`).

## Logging from a host app

```swift
import MetalPlayerCore

AppLog.info(.host, "Playback session started")
AppLog.warning("Network", "Retrying range request")  // ad-hoc category
```

`LogCategory` is `ExpressibleByStringLiteral`. To get a typed category:

```swift
extension LogCategory {
    static let emby = LogCategory("Emby")
}
```

Levels: `debug`, `info`, `notice`, `warning`, `error`.

The default minimum level is `.debug` in Debug builds and `.info` in Release. To change it at runtime:

```swift
AppLog.minimumLogLevel = .debug
```

## Log viewer

```swift
import MetalPlayerKit

LogViewerWindowController.shared.show()
```

The menu command `PlayerCommands.LogConsoleMenuCommand()` binds it to ⌥⌘L. The viewer can filter by level and category, search, copy, export and clear the log (clearing also truncates `player.log`).

## Reading logs from the terminal

```bash
tail -f ~/Library/Application\ Support/MetalPlayer/player.log

log stream --predicate 'subsystem == "com.metalplayer"' --level debug
log show --predicate 'subsystem == "com.metalplayer"' --last 10m --info --debug
```
