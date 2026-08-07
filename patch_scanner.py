import re

with open('lib/screens/scanner_screen.dart', 'r') as f:
    content = f.read()

# Update onAcceptWithDetails drop logic.
# The issue is `localOffset = renderBox.globalToLocal(details.offset);`
# The `details.offset` is the global position of the top-left of the draggable feedback.
# But DraggableResizableDocument has a 12px padding! So the top left of the *container* is at `dx - 12`.
# Thus, when we drop, we should just use `localOffset.dx + 12` (scaled) for dx.
# Oh wait, `details.offset` already corresponds to the top left of the draggable widget (which is left: dx - 12).
# So `localOffset.dx` *is* the new `dx - 12`.
# Therefore, `virtualDx = (localOffset.dx * scaleX) + 12.0`.
# AND we must call `moveDocumentToTop` if sourcePageIndex == pageKey.

replace_accept = """
                                        onAcceptWithDetails: (details) {
                                          final RenderBox renderBox = context.findRenderObject() as RenderBox;
                                          final localOffset = renderBox.globalToLocal(details.offset);

                                          // The virtual canvas represents a fixed physical A4 aspect ratio
                                          // but scales down to fit the device screen. We need to calculate
                                          // exactly how the 400x565.6 box is scaled inside its parent constraints.

                                          // Assuming FittedBox fits perfectly by width or height
                                          double scaleX = 400.0 / renderBox.size.width;
                                          double scaleY = 565.6 / renderBox.size.height;

                                          final data = details.data as Map<String, dynamic>;
                                          final doc = data['document'] as ScannedDocument;
                                          final sourcePageIndex = data['pageIndex'] as int;
                                          final sourceDocIndex = data['docIndex'] as int;

                                          // Compensate for the 12px drag padding offset in the Draggable
                                          double virtualDx = (localOffset.dx * scaleX) + 12.0;
                                          double virtualDy = (localOffset.dy * scaleY) + 12.0;

                                          // Local Strict bounds clamping for drag
                                          virtualDx = math.max(0.0, math.min(virtualDx, 400.0 - doc.width));
                                          virtualDy = math.max(0.0, math.min(virtualDy, 565.6 - doc.height));

                                          final newDoc = doc.copyWith(dx: virtualDx, dy: virtualDy);

                                          // Update State
                                          if (sourcePageIndex == pageKey) {
                                            ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(sourcePageIndex, sourceDocIndex, newDoc);
                                            ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(sourcePageIndex, sourceDocIndex);

                                            // Select the dropped document (it's now at the end of the list)
                                            final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                            if (currentDocsCount > 0) {
                                                setState(() {
                                                    _selectedPageIndex = pageKey;
                                                    _selectedDocIndex = currentDocsCount - 1;
                                                });
                                            }
                                          } else {
                                            ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(sourcePageIndex, sourceDocIndex);
                                            // Force add the new document directly into the target page
                                            final currentState = ref.read(scannedDocumentsProvider);
                                            final targetPageDocs = currentState[pageKey] ?? [];

                                            ref.read(scannedDocumentsProvider.notifier).state = {
                                              ...currentState,
                                              pageKey: [...targetPageDocs, newDoc],
                                            };

                                            setState(() {
                                                _selectedPageIndex = pageKey;
                                                _selectedDocIndex = targetPageDocs.length;
                                            });
                                          }
                                        },
"""

pattern = re.compile(r"                                        onAcceptWithDetails: \(details\) \{.*?                                        \},", re.DOTALL)
content = pattern.sub(replace_accept, content)

with open('lib/screens/scanner_screen.dart', 'w') as f:
    f.write(content)

