import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('checkForUpdates')
external JSPromise<JSAny?> _checkForUpdates();

class WebUpdateCheck {
  const WebUpdateCheck({
    required this.supported,
    this.registered,
    this.updateAvailable,
    this.error,
  });

  final bool supported;
  final bool? registered;
  final bool? updateAvailable;
  final String? error;
}

class WebUpdateService {
  WebUpdateService._();

  static final WebUpdateService instance = WebUpdateService._();

  Future<WebUpdateCheck> checkForUpdates({bool verbose = false}) async {
    try {
      final JSAny? resultAny = await _checkForUpdates().toDart;
      if (resultAny == null) {
        return const WebUpdateCheck(
          supported: true,
          registered: null,
          updateAvailable: null,
          error: 'checkForUpdates() returned no result',
        );
      }

      if (!resultAny.isA<JSObject>()) {
        return WebUpdateCheck(
          supported: true,
          registered: null,
          updateAvailable: null,
          error: 'Unexpected result type: ${resultAny.runtimeType}',
        );
      }

      final JSObject result = resultAny as JSObject;

      bool? readBool(String key) {
        final JSAny? value = result.getProperty(key.toJS);
        if (value == null || !value.isA<JSBoolean>()) return null;
        return (value as JSBoolean).toDart;
      }

      String? readString(String key) {
        final JSAny? value = result.getProperty(key.toJS);
        if (value == null) return null;
        if (value.isA<JSString>()) {
          return (value as JSString).toDart;
        }
        return value.toString();
      }

      return WebUpdateCheck(
        supported: readBool('supported') ?? true,
        registered: readBool('registered'),
        updateAvailable: readBool('updateAvailable'),
        error: readString('error'),
      );
    } catch (e) {
      return WebUpdateCheck(
        supported: true,
        registered: null,
        updateAvailable: null,
        error: e.toString(),
      );
    }
  }
}
