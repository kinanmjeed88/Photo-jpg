import sys

with open('lib/providers/app_state.dart', 'r') as f:
    content = f.read()

old_add_doc = """
    double currentDx = 10.0;
    double currentDy = 10.0;
    if (pageDocs.length == 1) {
      currentDx = 10.0 + newDocWidth + 10.0;
      currentDy = 10.0;
    } else if (pageDocs.length == 2) {
      currentDx = 10.0;
      currentDy = 10.0 + newDocHeight + 10.0;
    } else if (pageDocs.length >= 3) {
      currentDx = 10.0 + newDocWidth + 10.0;
      currentDy = 10.0 + newDocHeight + 10.0;
    }

    // Page Break Check (Stop Bleeding)
    if (currentDy + newDocHeight + margin > VIRTUAL_A4_HEIGHT) {
      pageIndex++;
      currentDx = margin;
      currentDy = margin;

      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: currentDx, dy: currentDy)]
      };
    } else {
      state = {
        ...state,
        pageIndex: [...pageDocs, newDoc.copyWith(dx: currentDx, dy: currentDy)]
      };
    }
"""

new_add_doc = """
    int currentIndex = pageDocs.length;
    if (currentIndex >= 4) {
      pageIndex++;
      currentIndex = 0;
      pageDocs = []; // New page
    }

    double currentDx = 10.0;
    double currentDy = 10.0;

    if (currentIndex == 0) {
      currentDx = 10.0;
      currentDy = 10.0;
    } else if (currentIndex == 1) {
      currentDx = 10.0 + newDocWidth + 10.0;
      currentDy = 10.0;
    } else if (currentIndex == 2) {
      currentDx = 10.0;
      currentDy = 10.0 + newDocHeight + 10.0;
    } else if (currentIndex == 3) {
      currentDx = 10.0 + newDocWidth + 10.0;
      currentDy = 10.0 + newDocHeight + 10.0;
    }

    state = {
      ...state,
      pageIndex: [...pageDocs, newDoc.copyWith(dx: currentDx, dy: currentDy)]
    };
"""
content = content.replace(old_add_doc.strip(), new_add_doc.strip())

with open('lib/providers/app_state.dart', 'w') as f:
    f.write(content)
