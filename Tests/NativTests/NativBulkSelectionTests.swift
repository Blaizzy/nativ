import Testing

@Suite("Bulk selection")
struct NativBulkSelectionTests {
    @Test("Leaving selection mode clears the selection")
    func leavingSelectionModeClearsSelection() {
        var selection = NativBulkSelection<String>()

        selection.toggleMode()
        selection.toggle("first")
        selection.toggleMode()

        #expect(!selection.isActive)
        #expect(selection.ids.isEmpty)
    }

    @Test("Toggling an item selects and deselects it")
    func togglingAnItemUpdatesSelection() {
        var selection = NativBulkSelection<String>()

        selection.toggle("first")
        #expect(selection.contains("first"))

        selection.toggle("first")
        #expect(!selection.contains("first"))
    }

    @Test("Select All only changes the supplied candidates")
    func selectAllOnlyChangesCandidates() {
        var selection = NativBulkSelection<String>()
        selection.toggle("hidden")
        let visible = Set(["first", "second"])

        selection.toggleAll(visible)
        #expect(selection.includesAll(visible))
        #expect(selection.contains("hidden"))

        selection.toggleAll(visible)
        #expect(!selection.contains("first"))
        #expect(!selection.contains("second"))
        #expect(selection.contains("hidden"))
    }

    @Test("Selecting all activates selection mode and replaces hidden items")
    func selectingAllReplacesSelection() {
        var selection = NativBulkSelection<String>()
        selection.toggle("hidden")

        selection.selectAll(["first", "second"])

        #expect(selection.isActive)
        #expect(selection.ids == ["first", "second"])
    }

    @Test("Retaining visible items removes hidden selections")
    func retainingVisibleItemsRemovesHiddenSelections() {
        var selection = NativBulkSelection<String>()
        selection.toggle("visible")
        selection.toggle("hidden")

        selection.retain(["visible"])

        #expect(selection.ids == ["visible"])
    }

    @Test("Finishing selection clears mode and selected items")
    func finishingSelectionResetsState() {
        var selection = NativBulkSelection<String>()
        selection.toggleMode()
        selection.toggle("first")

        selection.finish()

        #expect(!selection.isActive)
        #expect(selection.ids.isEmpty)
    }
}
