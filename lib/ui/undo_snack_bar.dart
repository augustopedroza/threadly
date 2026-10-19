import 'package:flutter/material.dart';

/// A short "[message] · Undo" snack bar that goes away on its own. Flutter
/// keeps snack bars with an action up until tapped unless told otherwise
/// (`persist` defaults to true when there's an action).
SnackBar undoSnackBar(String message, VoidCallback onUndo) => SnackBar(
  content: Text(message),
  persist: false,
  duration: const Duration(seconds: 6),
  action: SnackBarAction(label: 'Undo', onPressed: onUndo),
);
