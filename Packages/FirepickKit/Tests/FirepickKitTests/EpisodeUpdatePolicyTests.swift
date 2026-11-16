import Foundation
import Testing

@testable import FirepickCore

struct EpisodeUpdatePolicyTests {
  @Test
  func prefersPublishedProgressOverBonusPlaybackEntries() {
    let items = [
      MediaItem(
        vodId: "xgzy|90638",
        name: "今天是太阳雨",
        remarks: "更新至第20集",
        playURL: episodesURL(count: 39)
      ),
      MediaItem(
        vodId: "maoyan|158395",
        name: "今天是太阳雨",
        remarks: "更新至第19集",
        playURL: episodesURL(count: 21)
      ),
    ]

    let counts = EpisodeUpdatePolicy.sourceEpisodeCounts(
      from: items,
      matchingTitle: "今天是太阳雨"
    )

    #expect(counts == ["xgzy": 20, "maoyan": 19])
  }

  @Test
  func fallsBackToEpisodeEntriesWhenRemarksHaveNoProgress() {
    let items = [
      MediaItem(
        vodId: "hongniu|199246",
        name: "今天是太阳雨",
        remarks: "高清",
        playURL: episodesURL(count: 20)
      )
    ]

    let counts = EpisodeUpdatePolicy.sourceEpisodeCounts(
      from: items,
      matchingTitle: "今天是太阳雨"
    )

    #expect(counts == ["hongniu": 20])
  }

  @Test
  func ignoresOtherTitlesAndCoalescesDuplicateProviders() {
    let items = [
      MediaItem(
        vodId: "ffzy|100258",
        name: "今天是太阳雨",
        remarks: "更新至19集"
      ),
      MediaItem(
        vodId: "ffzy|100259",
        name: "今天是太阳雨",
        remarks: "更新至第20集"
      ),
      MediaItem(
        vodId: "xgzy|90638",
        name: "另一部剧",
        remarks: "全24集"
      ),
    ]

    let counts = EpisodeUpdatePolicy.sourceEpisodeCounts(
      from: items,
      matchingTitle: "今天是太阳雨"
    )

    #expect(counts == ["ffzy": 20])
  }

  @Test
  func skipsAutomaticCheckUntilRefreshIntervalHasElapsed() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(EpisodeUpdatePolicy.isCheckDue(lastCheckedAt: nil, now: now))
    #expect(
      !EpisodeUpdatePolicy.isCheckDue(
        lastCheckedAt: now.addingTimeInterval(-11 * 60),
        now: now
      )
    )
    #expect(
      EpisodeUpdatePolicy.isCheckDue(
        lastCheckedAt: now.addingTimeInterval(-12 * 60),
        now: now
      )
    )
  }

  private func episodesURL(count: Int) -> String {
    (1...count)
      .map { "第\($0)集$https://media.example.com/\($0).m3u8" }
      .joined(separator: "#")
  }
}
