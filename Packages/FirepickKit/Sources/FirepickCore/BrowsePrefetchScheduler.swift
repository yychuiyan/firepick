import Foundation

public enum BrowsePrefetchScheduler {
  /// Runs work with a fixed concurrency ceiling while preserving every result.
  /// Results arrive in completion order; callers should key them by their input.
  public static func run<Element: Sendable, Output: Sendable>(
    _ elements: [Element],
    maxConcurrent: Int,
    operation: @escaping @Sendable (Element) async -> Output
  ) async -> [Output] {
    guard !elements.isEmpty else { return [] }
    let limit = max(1, min(maxConcurrent, elements.count))

    return await withTaskGroup(of: Output.self) { group in
      var iterator = elements.makeIterator()
      for _ in 0..<limit {
        guard let element = iterator.next() else { break }
        group.addTask {
          await operation(element)
        }
      }

      var results: [Output] = []
      while let result = await group.next() {
        results.append(result)
        guard !Task.isCancelled, let element = iterator.next() else { continue }
        group.addTask {
          await operation(element)
        }
      }
      return results
    }
  }
}
