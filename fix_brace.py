import sys

with open('lib/screens/scanner_screen.dart', 'r') as f:
    content = f.read()

old = """
          for (var f in finalFiles) {
            final decoded = await decodeImageFromList(await f.readAsBytes());
           double aspect = decoded.width / decoded.height;
           double docWidth = 300;
           double docHeight = docWidth / aspect;

           ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(
            file: f,
            type: docType,
            width: docWidth,
            height: docHeight,
          ), ref.read(appStateProvider));
        }
      }
    } catch (e) {
"""

new = """
          for (var f in finalFiles) {
            final decoded = await decodeImageFromList(await f.readAsBytes());
           double aspect = decoded.width / decoded.height;
           double docWidth = 300;
           double docHeight = docWidth / aspect;

           ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(
            file: f,
            type: docType,
            width: docWidth,
            height: docHeight,
          ), ref.read(appStateProvider));
          }
        }
      }
    } catch (e) {
"""

content = content.replace(old, new)
with open('lib/screens/scanner_screen.dart', 'w') as f:
    f.write(content)
