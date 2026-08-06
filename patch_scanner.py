import sys

with open('lib/screens/scanner_screen.dart', 'r') as f:
    content = f.read()

old_scan_doc = """
    try {
      final File? processedFile = await _scannerService.scanDocument(source: source);
      if (processedFile == null) return;

      setState(() {
        _isProcessing = true;
      });

      if (mounted) {
        // Document type classification
        final docType = await _scannerService.classifyDocument(processedFile);

        // Smart recognition for cropping
        final bool smartRecog = ref.read(appStateProvider).smartRecognition;
        List<File> finalFiles = [processedFile];

        if (smartRecog) {
           finalFiles = await _scannerService.processSmartRecognition(processedFile);
        }

        for (var f in finalFiles) {
           final decoded = await decodeImageFromList(await f.readAsBytes());
"""

new_scan_doc = """
    try {
      // Pick multiple images if gallery
      final List<File> pickedFiles = [];
      if (source == ImageSource.gallery) {
        final List<File>? files = await _scannerService.scanMultipleDocuments();
        if (files != null && files.isNotEmpty) {
          pickedFiles.addAll(files);
        }
      } else {
        final File? file = await _scannerService.scanDocument(source: source);
        if (file != null) {
          pickedFiles.add(file);
        }
      }

      if (pickedFiles.isEmpty) return;

      setState(() {
        _isProcessing = true;
      });

      if (mounted) {
        final bool smartRecog = ref.read(appStateProvider).smartRecognition;

        for (var processedFile in pickedFiles) {
          // Document type classification
          final docType = await _scannerService.classifyDocument(processedFile);

          List<File> finalFiles = [processedFile];

          if (smartRecog) {
            finalFiles = await _scannerService.processSmartRecognition(processedFile);
            if (finalFiles.isEmpty) {
              // Smart Manual Cropper Fallback
              final File? manuallyCropped = await _scannerService.manualCrop(processedFile.path);
              if (manuallyCropped != null) {
                finalFiles = [manuallyCropped];
              } else {
                finalFiles = [processedFile]; // Or continue if we don't want to add it
              }
            }
          }

          for (var f in finalFiles) {
            final decoded = await decodeImageFromList(await f.readAsBytes());
"""
content = content.replace(old_scan_doc.strip(), new_scan_doc.strip())

with open('lib/screens/scanner_screen.dart', 'w') as f:
    f.write(content)


with open('lib/services/scanner_service.dart', 'r') as f:
    scanner = f.read()

old_scan_doc_service = """
  Future<File?> scanDocument({ImageSource source = ImageSource.camera}) async {
    final XFile? image = await _picker.pickImage(source: source);
    if (image == null) return null;

    final CroppedFile? croppedFile = await ImageCropper().cropImage(
      sourcePath: image.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'تعديل الصورة',
          toolbarColor: const Color(0xFF1E293B),
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'تعديل الصورة'),
      ],
    );

    if (croppedFile != null) {
      return File(croppedFile.path);
    }
    return null;
  }
"""

new_scan_doc_service = """
  Future<File?> manualCrop(String sourcePath) async {
    final CroppedFile? croppedFile = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'تعديل الصورة',
          toolbarColor: const Color(0xFF1E293B),
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'تعديل الصورة'),
      ],
    );

    if (croppedFile != null) {
      return File(croppedFile.path);
    }
    return null;
  }

  Future<File?> scanDocument({ImageSource source = ImageSource.camera}) async {
    final XFile? image = await _picker.pickImage(source: source);
    if (image == null) return null;

    return manualCrop(image.path);
  }

  Future<List<File>?> scanMultipleDocuments() async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return null;

    // As per instruction, maybe we process them sequentially and inject them.
    // If they go through multi-picker, we probably just return the original files,
    // and rely on `processSmartRecognition` or manual crop for each.
    // Actually, manual crop on 10 images might be annoying, but the mandate states:
    // "Iterate through the selected images, processing each through the pipeline, and injecting all resulting cropped files into the state sequentially."

    return images.map((x) => File(x.path)).toList();
  }
"""

scanner = scanner.replace(old_scan_doc_service.strip(), new_scan_doc_service.strip())
with open('lib/services/scanner_service.dart', 'w') as f:
    f.write(scanner)
