## Directive 0.5: Implementation Strategy Report

1. **Queue Data Structure**:
   - A `List<DocumentType>` managed as an immutable state inside an `ActiveSessionState` model in `AppState`.
   - The queue will be created when a session is initialized and kept immutable to guarantee no state leakage between sessions.

2. **Queue Generation Algorithm (Default Ordering & Multi-Frame)**:
   - Precedence: Passport -> National ID -> Housing Card -> Ration Card.
   - For multi-frame logic, National ID and Housing Card generally require both front and back. (Based on context, NationalID needs Front/Back, HousingCard needs Front/Back, Passport is single, Ration Card is single/multi depending on typical usage, but let's assume standard behavior or explicit frames). We will evaluate the boolean flags and generate a queue like:
     - `appState.hasPassport` -> `[DocumentType.passport]`
     - `appState.hasNationalId` -> `[DocumentType.nationalId, DocumentType.nationalId]` (Front & Back)
     - `appState.hasHousingCard` -> `[DocumentType.housingCard, DocumentType.housingCard]` (Front & Back)
     - `appState.hasRationCard` -> `[DocumentType.rationCard, DocumentType.rationCard]` (Front & Back)
   - The ordering rule will deterministically append these based on the strict precedence order.

3. **State Injection & Pointer Management (Silent Advancement Fix)**:
   - We will introduce `List<DocumentType> captureQueue` and `int currentCaptureIndex` in `AppState`.
   - When a document is scanned, `scannedDocuments.length` is NOT the only source of truth. We track `currentCaptureIndex` which increments after a successful capture.
   - If a capture is deleted, `currentCaptureIndex` decrements (up to 0) for that session.

4. **Session Leakage Prevention**:
   - A new API: `appStateNotifier.startSession()` generates the `captureQueue` and resets `currentCaptureIndex = 0`.
   - `appStateNotifier.endSession()` resets the queue and pointer.

5. **Aspect Ratio Centralization**:
   - Introduce an extension on `DocumentType` (e.g., `extension DocumentTypeSettings on DocumentType`) providing the `aspectRatio` (e.g., 0.45 for NationalID/Housing, 0.85 for RationCard, 0.90 for Passport).

6. **Edge Case Handling**:
   - If NO booleans are selected, the queue defaults to `[DocumentType.unknown]` or `[DocumentType.a4Document]`.
   - If the user captures MORE frames than the generated queue length, the queue yields the last type repeatedly, or `DocumentType.a4Document`.
