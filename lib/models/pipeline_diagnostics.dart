class PipelineDiagnostics {
  final int startTime;
  int endTime;
  int totalCandidatesGenerated;
  Map<String, int> rejectionReasons;
  List<double> finalScores;
  Map<String, int> memoryStates; // e.g. "MatAllocated", "MatDisposed"

  PipelineDiagnostics({int? startTime})
    : startTime = startTime ?? DateTime.now().millisecondsSinceEpoch,
      endTime = 0,
      totalCandidatesGenerated = 0,
      rejectionReasons = {},
      finalScores = [],
      memoryStates = {'allocated': 0, 'disposed': 0};

  void markComplete() {
    endTime = DateTime.now().millisecondsSinceEpoch;
  }

  int get executionTimeMs => endTime > 0
      ? endTime - startTime
      : DateTime.now().millisecondsSinceEpoch - startTime;

  void addCandidate() {
    totalCandidatesGenerated++;
  }

  void addRejection(String reason) {
    rejectionReasons[reason] = (rejectionReasons[reason] ?? 0) + 1;
  }

  void addScore(double score) {
    finalScores.add(score);
  }

  void trackAllocation() {
    memoryStates['allocated'] = (memoryStates['allocated'] ?? 0) + 1;
  }

  void trackDisposal() {
    memoryStates['disposed'] = (memoryStates['disposed'] ?? 0) + 1;
  }

  int get activeAllocations =>
      (memoryStates['allocated'] ?? 0) - (memoryStates['disposed'] ?? 0);

  @override
  String toString() {
    return 'PipelineDiagnostics(Execution Time: ${executionTimeMs}ms, '
        'Candidates: $totalCandidatesGenerated, '
        'Rejections: $rejectionReasons, '
        'Scores: $finalScores, '
        'Active Memory Allocations: $activeAllocations)';
  }
}
