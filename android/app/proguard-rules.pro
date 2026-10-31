# shared_preferences_android >= 2.5.0 is called from Dart via JNI (Pigeon JNI); R8 can't see
# those call sites, so keep the plugin's classes and members intact.
-keep class io.flutter.plugins.sharedpreferences.** { *; }
# Runtime support for package:jni.
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }
# Kotlin types that package:jni looks up by name (suspend-function bridging). Without these,
# R8 renames e.g. kotlin.coroutines.Continuation and JNI method lookups fail at runtime.
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
