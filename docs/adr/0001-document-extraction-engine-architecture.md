# ADR 0001: Document Extraction Engine Architecture

## Status
Accepted

## Context
The document scanning feature requires a robust, performant, and resilient extraction engine (v1.0 Production-Grade). The current implementation in `scanner_service.dart` lacks modularity, hardcodes processing thresholds, and doesn't handle isolate lifecycles/cancellation correctly, leading to potential memory leaks, stale UI updates, and difficulty in fine-tuning for different conditions. We need a "Track-Merge-Validate-Score" pipeline adhering to strict Non-Functional Requirements (NFRs).

## Decision
We have decided to architect the extraction engine with the following core principles:

1.  **Configuration-Driven:** All algorithmic thresholds (IoU, solidity, area ratios, weights) are encapsulated in a `DocumentScannerConfig` model. This eliminates hardcoded values and allows for remote configuration (OTA updates, A/B testing) via JSON serialization.
2.  **Telemetry & Observability:** A `PipelineDiagnostics` class tracks execution time, candidate generation, rejection reasons, memory allocations, and final scores. This is crucial for debugging and maintaining the ≤ 500ms performance budget.
3.  **Modular Data Structures:** The pipeline uses a distinct `Candidate` model, enriched with `Metrics` (Geometry, Quality, Consensus). This separates the structural data (contours, rects) from the evaluation logic.
4.  **Strategic Interface:** The entire engine is hidden behind an abstract `DocumentDetectionProvider` interface. This decoupling allows future iterations to seamlessly swap the underlying implementation (e.g., from OpenCV to YOLO or a cloud-based solution) without breaking the core application logic.
5.  **Strict Lifecycle Management:** (To be implemented in subsequent phases) Scan requests will be tracked via unique Request IDs to enable immediate cancellation of stale background isolates, preventing race conditions.

## Consequences
*   **Positive:** Highly testable architecture, easily tunable pipeline, clear separation of concerns, and future-proofed for alternative detection models.
*   **Negative:** Increased initial complexity due to the introduction of multiple specialized models and interfaces compared to the previous single-function approach.
