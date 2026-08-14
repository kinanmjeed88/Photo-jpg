import 'package:doc_scanner_app/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps four separated document regions as four results', () {
    const regions = <DocumentRegion>[
      DocumentRegion(left: 20, top: 20, right: 220, bottom: 300, area: 56_000),
      DocumentRegion(left: 260, top: 20, right: 460, bottom: 300, area: 56_000),
      DocumentRegion(left: 20, top: 340, right: 220, bottom: 620, area: 56_000),
      DocumentRegion(
        left: 260,
        top: 340,
        right: 460,
        bottom: 620,
        area: 56_000,
      ),
      // The second threshold pass can return a nearly identical outline.
      DocumentRegion(left: 24, top: 24, right: 216, bottom: 296, area: 52_224),
    ];

    final selected = selectDistinctDocumentRegions(regions);

    expect(selected, hasLength(4));
    expect(selected.map((region) => '${region.left}:${region.top}'), <String>[
      '20:20',
      '260:20',
      '20:340',
      '260:340',
    ]);
  });

  test('removes overlapping outlines but keeps adjacent documents', () {
    const regions = <DocumentRegion>[
      DocumentRegion(left: 10, top: 10, right: 210, bottom: 290, area: 56_000),
      DocumentRegion(left: 12, top: 12, right: 208, bottom: 288, area: 54_096),
      DocumentRegion(left: 225, top: 10, right: 425, bottom: 290, area: 56_000),
    ];

    expect(selectDistinctDocumentRegions(regions), hasLength(2));
  });
}
