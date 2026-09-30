import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A picture chosen on the admin's computer.
typedef PickedPicture = ({List<int> bytes, String name});

/// Opens the browser's file window, and answers null when the admin closes it
/// without choosing. A provider so tests hand in a file without a window.
final picturePickerProvider = Provider<Future<PickedPicture?> Function()>(
  (ref) => _pickFromComputer,
);

Future<PickedPicture?> _pickFromComputer() async {
  final result = await FilePicker.pickFiles(
    type: FileType.custom,
    // The server decodes the bytes whatever the name; this only filters the
    // window to what it will accept.
    allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
    withData: true,
  );
  final file = result?.files.singleOrNull;
  final bytes = file?.bytes;
  if (file == null || bytes == null) return null;
  return (bytes: bytes, name: file.name);
}
