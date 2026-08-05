import re

with open('lib/screens/scanner_screen.dart', 'r') as f:
    content = f.read()

# Make sure we only do exactly one replacement for the state variables
content = re.sub(r'int\? _selectedDocIndex;', 'int? _selectedPageIndex;\n  int? _selectedDocIndex;', content, count=1)

# Replace scannedDocumentsProvider access
content = content.replace('final scannedDocuments = ref.watch(scannedDocumentsProvider);', 'final pages = ref.watch(scannedDocumentsProvider);')
content = content.replace('final scannedDocuments = ref.read(scannedDocumentsProvider);', 'final pages = ref.read(scannedDocumentsProvider);')

# Replace the totalPages calculation logic entirely with empty string
old_total_pages_regex = r"// Calculate total pages needed based on highest pageIndex.*?int totalPages = 1;.*?if \(scannedDocuments\.isNotEmpty\) \{.*?for \(var doc in scannedDocuments\) \{.*?if \(doc\.pageIndex >= totalPages\) \{.*?totalPages = doc\.pageIndex \+ 1;.*?}.*?}.*?}"
content = re.sub(old_total_pages_regex, '', content, flags=re.DOTALL)

# Replace ListView.builder itemCount
content = content.replace('itemCount: totalPages,', 'itemCount: pages.length,')

# Replace scannedDocuments.isEmpty with pages.isEmpty
content = content.replace('scannedDocuments.isEmpty', 'pages.isEmpty')

# Replace _generatePdf parameters
old_generate_pdf = '''final pdfFile = await _pdfService.generatePdf(
        scannedDocuments: scannedDocuments,
        state: state,
        uiCanvasWidth: _lastKnownCanvasWidth,
        uiCanvasHeight: _lastKnownCanvasHeight,
      );'''
new_generate_pdf = '''final pdfFile = await _pdfService.generatePdf(
        pages: pages,
        state: state,
        uiCanvasWidth: _lastKnownCanvasWidth,
        uiCanvasHeight: _lastKnownCanvasHeight,
      );'''
content = content.replace(old_generate_pdf, new_generate_pdf)

# Replace docsOnPage map iteration
old_docs_on_page = '''final docsOnPage = scannedDocuments.asMap().entries.where((e) => e.value.pageIndex == pageIndex).toList();'''
new_docs_on_page = '''final page = pages[pageIndex];
                            final docsOnPage = page.documents.asMap().entries.toList();'''
content = content.replace(old_docs_on_page, new_docs_on_page)

# Replace sort logic
old_sort_logic = '''sortedDocs.sort((a, b) {
                                        if (a.key == _selectedDocIndex) return 1;
                                        if (b.key == _selectedDocIndex) return -1;
                                        return 0;
                                      });'''
new_sort_logic = '''sortedDocs.sort((a, b) {
                                        bool aSelected = (_selectedPageIndex == pageIndex && _selectedDocIndex == a.key);
                                        bool bSelected = (_selectedPageIndex == pageIndex && _selectedDocIndex == b.key);
                                        if (aSelected) return 1;
                                        if (bSelected) return -1;
                                        return 0;
                                      });'''
content = content.replace(old_sort_logic, new_sort_logic)

# Replace single setState for deselect
content = content.replace('setState(() => _selectedDocIndex = null);', 'setState(() {\n                                            _selectedPageIndex = null;\n                                            _selectedDocIndex = null;\n                                          });')

# Replace widget DraggableResizableDocument
old_draggable_regex = r"return DraggableResizableDocument\(.*?onLayoutUpdate:.*?\}\,.*?\);"
new_draggable = '''return DraggableResizableDocument(
                                                key: ValueKey('${pageIndex}_${doc.file.path}'),
                                                document: doc,
                                                pageIndex: pageIndex,
                                                docIndex: docIndex,
                                                isSelected: _selectedPageIndex == pageIndex && _selectedDocIndex == docIndex,
                                                canvasWidth: canvasWidth,
                                                canvasHeight: canvasHeight,
                                                onTap: () {
                                                  setState(() {
                                                    _selectedPageIndex = pageIndex;
                                                    _selectedDocIndex = docIndex;
                                                  });
                                                },
                                                onEdit: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) => ImageEditorScreen(
                                                        pageIndex: pageIndex,
                                                        documentIndex: docIndex
                                                      ),
                                                    ),
                                                  );
                                                },
                                                onDelete: () {
                                                  showDialog(
                                                    context: context,
                                                    builder: (context) => AlertDialog(
                                                      title: const Text('تأكيد الحذف'),
                                                      content: const Text('هل أنت متأكد من أنك تريد حذف هذا المستمسك؟'),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () => Navigator.pop(context),
                                                          child: const Text('إلغاء'),
                                                        ),
                                                        TextButton(
                                                          onPressed: () {
                                                            ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(pageIndex, docIndex);
                                                            if (_selectedPageIndex == pageIndex && _selectedDocIndex == docIndex) {
                                                              setState(() {
                                                                _selectedPageIndex = null;
                                                                _selectedDocIndex = null;
                                                              });
                                                            } else if (_selectedPageIndex == pageIndex && _selectedDocIndex != null && _selectedDocIndex! > docIndex) {
                                                              setState(() {
                                                                _selectedDocIndex = _selectedDocIndex! - 1;
                                                              });
                                                            }
                                                            Navigator.pop(context);
                                                          },
                                                          child: const Text('حذف', style: TextStyle(color: Colors.red)),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                                onLayoutUpdate: (pIndex, dIndex, dx, dy, width, height) {
                                                  ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                    pIndex,
                                                    dIndex,
                                                    dx: dx,
                                                    dy: dy,
                                                    width: width,
                                                    height: height,
                                                  );
                                                },
                                              );'''

content = re.sub(old_draggable_regex, new_draggable, content, flags=re.DOTALL)

with open('lib/screens/scanner_screen.dart', 'w') as f:
    f.write(content)
