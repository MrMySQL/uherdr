enum AppHotkeys {
    static func tabSelectionKey(at index: Int) -> Character? {
        guard (0..<10).contains(index) else { return nil }
        return Character(String((index + 1) % 10))
    }
}
