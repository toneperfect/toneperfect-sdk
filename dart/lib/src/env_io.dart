import 'dart:io' show Platform;

/// Dart VM, Flutter mobile and desktop: read the process environment.
String? environmentVariable(String name) => Platform.environment[name];
