import re

with open('lib/providers/app_state.dart', 'r') as f:
    content = f.read()

# Make sure that Z-indexing allows dragging items to top.
# Actually, the Z-indexing drop is done in scanner_screen.dart (by removing and adding to list).
# Wait, when moving items within the same page in scanner_screen.dart:
# ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(sourcePageIndex, sourceDocIndex, newDoc);
# This updates in place, but we need it to move to the end of the list for Z-indexing.
# I'll create a `moveDocumentToTop` method in AppStateNotifier.

add_to_top_code = """
  void moveDocumentToTop(int pageIndex, int docIndex) {
    if (!state.containsKey(pageIndex)) return;
    final pageDocs = List<ScannedDocument>.from(state[pageIndex]!);
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    final doc = pageDocs.removeAt(docIndex);
    pageDocs.add(doc);

    state = {
      ...state,
      pageIndex: pageDocs,
    };
  }
"""

if "moveDocumentToTop" not in content:
    content = content.replace("void clear() {", add_to_top_code + "\n  void clear() {")
    with open('lib/providers/app_state.dart', 'w') as f:
        f.write(content)
    print("Added moveDocumentToTop")
