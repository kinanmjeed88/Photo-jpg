import re

with open('lib/screens/image_editor_screen.dart', 'r') as f:
    content = f.read()

# Add Debouncer, Isolate Pipeline, and ValueNotifier

# First, imports
import_statements = """import 'dart:async';
import 'package:flutter/foundation.dart';
"""
if "import 'dart:async';" not in content:
    content = content.replace("import 'package:flutter/material.dart';", import_statements + "import 'package:flutter/material.dart';")

# Replace ImageEditorScreenState
editor_state_replace = """
class _ImageEditorScreenState extends ConsumerState<ImageEditorScreen> {
  final GlobalKey<ExtendedImageEditorState> editorKey = GlobalKey<ExtendedImageEditorState>();

  double _brightness = 0;
  double _contrast = 1;
  double _sharpness = 0;
  bool _isProcessing = false;

  Timer? _debounceTimer;
  ValueNotifier<Uint8List?> _previewImage = ValueNotifier<Uint8List?>(null);
  Uint8List? _originalBytes;
  int _isolateTaskCounter = 0;
  bool _isLoadingPreview = false;

  @override
  void initState() {
    super.initState();
    _loadOriginalBytes();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _previewImage.dispose();
    super.dispose();
  }

  Future<void> _loadOriginalBytes() async {
    final pageDocs = ref.read(scannedDocumentsProvider)[widget.pageIndex];
    if (pageDocs == null) return;
    final doc = pageDocs[widget.documentIndex];
    _originalBytes = await doc.file.readAsBytes();
  }

  void _onSliderChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    // We update the local UI sliders immediately without blocking.
    // The ColorFiltered widget already handles brightness/contrast instantly.
    // But for Sharpness, we need OpenCV, so we debounce and generate a preview.

    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (_originalBytes != null) {
        _generateLivePreview();
      }
    });
  }

  Future<void> _generateLivePreview() async {
    if (_originalBytes == null) return;

    final int currentTaskId = ++_isolateTaskCounter;
    setState(() => _isLoadingPreview = true);

    try {
      final args = {
        'bytes': _originalBytes!,
        // We only pass sharpness for the live preview because brightness/contrast
        // is ALREADY handled instantly at 60fps by ColorFiltered widget in the UI!
        // Wait, if we are returning a Uint8List to display, it will be inside ColorFiltered.
        // So we should ONLY apply sharpness in this preview.
        'sharpness': _sharpness,
      };

      // Create a top-level isolate function for just sharpness
      final processedBytes = await compute(_runPreviewIsolate, args);

      // Only update if this is the latest task
      if (currentTaskId == _isolateTaskCounter) {
        _previewImage.value = processedBytes;
        if (mounted) setState(() => _isLoadingPreview = false);
      }
    } catch (e) {
      print('Preview Isolate error: $e');
      if (currentTaskId == _isolateTaskCounter && mounted) {
        setState(() => _isLoadingPreview = false);
      }
    }
  }

"""

pattern = re.compile(r"class _ImageEditorScreenState extends ConsumerState<ImageEditorScreen> \{.*?(?=\n  Future<void> _saveToGallery\(\))", re.DOTALL)
content = pattern.sub(editor_state_replace, content)

# Change the build method to use ValueListenableBuilder

build_replacement = """
  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(scannedDocumentsProvider);
    if (!pages.containsKey(widget.pageIndex)) return const Scaffold();

    final pageDocs = pages[widget.pageIndex]!;
    if (widget.documentIndex >= pageDocs.length) return const Scaffold();

    final doc = pageDocs[widget.documentIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: [
          if (_isLoadingPreview)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'حفظ في المعرض',
            onPressed: _isProcessing ? null : _saveToGallery,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'تطبيق التعديلات',
            onPressed: _isProcessing ? null : _applyChanges,
          ),
        ],
      ),
      body: _isProcessing
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix([
                    _contrast, 0, 0, 0, _brightness,
                    0, _contrast, 0, 0, _brightness,
                    0, 0, _contrast, 0, _brightness,
                    0, 0, 0, 1, 0,
                  ]),
                  child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: _previewImage,
                    builder: (context, previewBytes, child) {
                      return previewBytes != null
                        ? ExtendedImage.memory(
                            previewBytes,
                            fit: BoxFit.contain,
                            mode: ExtendedImageMode.editor,
                            extendedImageEditorKey: editorKey,
                            initEditorConfigHandler: (ExtendedImageState? state) {
                              return EditorConfig(
                                maxScale: 8.0,
                                cropRectPadding: const EdgeInsets.all(20.0),
                                hitTestSize: 20.0,
                              );
                            },
                          )
                        : ExtendedImage.file(
                            doc.file,
                            fit: BoxFit.contain,
                            mode: ExtendedImageMode.editor,
                            extendedImageEditorKey: editorKey,
                            initEditorConfigHandler: (ExtendedImageState? state) {
                              return EditorConfig(
                                maxScale: 8.0,
                                cropRectPadding: const EdgeInsets.all(20.0),
                                hitTestSize: 20.0,
                              );
                            },
                          );
                    }
                  ),
                ),
              ),
              Container(
                color: const Color(0xFF1E293B),
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.brightness_6, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _brightness,
                            min: -100,
                            max: 100,
                            onChanged: (v) {
                              setState(() => _brightness = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.contrast, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _contrast,
                            min: 0.5,
                            max: 3.0,
                            onChanged: (v) {
                              setState(() => _contrast = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.lens_blur, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _sharpness,
                            min: 0.0,
                            max: 10.0,
                            onChanged: (v) {
                              setState(() => _sharpness = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
    );
  }
"""

pattern_build = re.compile(r"  @override\n  Widget build\(BuildContext context\) \{.*", re.DOTALL)
content = pattern_build.sub(build_replacement, content)

with open('lib/screens/image_editor_screen.dart', 'w') as f:
    f.write(content)
