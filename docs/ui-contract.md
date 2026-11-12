# UI integration contract

The placeholder UI is intentionally disconnected from source and playback
implementation details. The production design should bind to:

- `AppModel.configuration` and `AppModel.selectedSite` for source navigation
- `AppModel.homeResult` for categories and media grids
- `AppModel.detailResult` and `EpisodeParser.lines` for details and episodes
- `AppModel.searchSections` for cross-source search results
- `AppModel.history` and `AppModel.favorites` for the local library
- `PlaybackRequest` and `AVPlayerEngine` for playback
- `AppModel.bridgeHealth` and `AppModel.errorMessage` for bridge and failure UI

Pages must not parse CatVod API strings or decide whether a source is local or
Bridge-backed. Source routing remains owned by `SourceRouter`.

The design system should replace only visual components and navigation. It
must preserve these functional states:

- source unavailable or Bridge offline
- loading, empty, error, retry, and cancellation
- playback loading, buffering, paused, ended, and failure
- accessibility labels, Dynamic Type, VoiceOver, and Reduce Motion

