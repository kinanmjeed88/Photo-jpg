import re

with open('lib/providers/app_state.dart', 'r') as f:
    content = f.read()

def replace_addDocument(match):
    return """
  void addDocument(ScannedDocument doc, AppState appState) {
    const double VIRTUAL_A4_WIDTH = 400.0;
    const double VIRTUAL_A4_HEIGHT = 565.6; // 400 * 1.414
    const double margin = 10.0;

    DocumentType effectiveType = doc.type != DocumentType.unknown
        ? doc.type
        : _guessDocumentType(appState);

    // Keep the actual aspect ratio, but scale if it's too large
    double newDocWidth = doc.width;
    double newDocHeight = doc.height;

    // Default scaling strategy if width is exactly 300 (which is the default from scanner screen)
    if (newDocWidth == 300) {
        if (effectiveType == DocumentType.a4Document) {
          newDocWidth = VIRTUAL_A4_WIDTH;
        } else if (effectiveType == DocumentType.passport) {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.85;
        } else if (effectiveType == DocumentType.rationCard) {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.90;
        } else {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.42; // default for ID cards
        }

        // Maintain the intrinsic aspect ratio
        double aspect = doc.width / doc.height;
        newDocHeight = newDocWidth / aspect;
    }

    if (effectiveType == DocumentType.a4Document) {
        // Enforce full canvas for A4
        newDocWidth = VIRTUAL_A4_WIDTH;
        newDocHeight = VIRTUAL_A4_HEIGHT;
    }

    // Clamp dimensions to canvas limits to prevent overflow
    if (newDocWidth > VIRTUAL_A4_WIDTH) {
        double aspect = newDocWidth / newDocHeight;
        newDocWidth = VIRTUAL_A4_WIDTH;
        newDocHeight = newDocWidth / aspect;
    }
    if (newDocHeight > VIRTUAL_A4_HEIGHT) {
        double aspect = newDocWidth / newDocHeight;
        newDocHeight = VIRTUAL_A4_HEIGHT;
        newDocWidth = newDocHeight * aspect;
    }

    if (appState.displayMethod == DisplayMethod.frontOnly && state.isNotEmpty && (state[0] ?? []).isNotEmpty) {
      return;
    }

    ScannedDocument newDoc = doc.copyWith(
      type: effectiveType,
      width: newDocWidth,
      height: newDocHeight,
    );

    if (state.isEmpty) {
      state = {0: [newDoc.copyWith(dx: margin, dy: margin)]};
      return;
    }

    int pageIndex = state.keys.reduce(math.max);
    List<ScannedDocument> pageDocs = List<ScannedDocument>.from(state[pageIndex] ?? []);

    if (appState.displayMethod == DisplayMethod.twoPages && pageDocs.isNotEmpty) {
      pageIndex++;
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: margin, dy: margin)]
      };
      return;
    }

    if (pageDocs.isEmpty) {
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: effectiveType == DocumentType.a4Document ? 0 : margin, dy: effectiveType == DocumentType.a4Document ? 0 : margin)],
      };
      return;
    }

    if (effectiveType == DocumentType.a4Document) {
      pageIndex++;
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: 0, dy: 0)],
      };
      return;
    }

    // Calculate layout dynamically based on actual sizes
    double currentDx = margin;
    double currentDy = margin;

    // Find bottom-most item to place below it, or right-most item to place next to it
    if (pageDocs.length == 1) {
       currentDx = margin + pageDocs[0].width + margin;
       currentDy = margin;
       if (currentDx + newDocWidth > VIRTUAL_A4_WIDTH) {
           currentDx = margin;
           currentDy = margin + pageDocs[0].height + margin;
       }
    } else if (pageDocs.length == 2) {
       currentDx = margin;
       currentDy = margin + math.max(pageDocs[0].height, pageDocs[1].height) + margin;
    } else if (pageDocs.length == 3) {
       currentDx = margin + pageDocs[2].width + margin;
       currentDy = pageDocs[2].dy;
       if (currentDx + newDocWidth > VIRTUAL_A4_WIDTH) {
           currentDx = margin;
           currentDy = pageDocs[2].dy + pageDocs[2].height + margin;
       }
    }

    // If it still overflows height or max 4 items, new page
    if (pageDocs.length >= 4 || currentDy + newDocHeight > VIRTUAL_A4_HEIGHT) {
      pageIndex++;
      pageDocs = [];
      currentDx = margin;
      currentDy = margin;
    }

    state = {
      ...state,
      pageIndex: [...pageDocs, newDoc.copyWith(dx: currentDx, dy: currentDy)]
    };
  }
"""

# Replace the old addDocument method using regex
pattern = re.compile(r"void addDocument\(ScannedDocument doc, AppState appState\).*?DocumentType _guessDocumentType", re.DOTALL)

new_content = pattern.sub(replace_addDocument(None) + "\n  DocumentType _guessDocumentType", content)

# Check if anything changed
if new_content == content:
    print("Failed to replace addDocument!")
else:
    with open('lib/providers/app_state.dart', 'w') as f:
        f.write(new_content)
    print("Replaced addDocument successfully!")
