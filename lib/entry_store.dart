import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'entry_parser.dart';

/// 入口地址的持久化：只存"连哪儿"，不存任何凭据。
///
/// 刻意保持极薄 —— 没有数据库、没有缓存层、没有变更通知。
/// 全 App 只有一处需要读它（启动时），一处需要写它（连接/切换地址时）。
class EntryStore {
  EntryStore({SharedPreferences? prefs}) : _injected = prefs;

  /// 存进去的一定是 origin（无 path/query/fragment），见 [save]。
  static const String _key = 'entry_origin';

  final SharedPreferences? _injected;
  SharedPreferences? _cached;

  Future<SharedPreferences> get _prefs async =>
      _cached ??= _injected ?? await SharedPreferences.getInstance();

  /// 读取上次用的入口地址。
  ///
  /// 读不到、或存的值已经解析不了（比如手改过配置文件），就退回默认入口。
  /// **永远不抛异常** —— 启动路径上不该因为存储问题而崩。
  ///
  /// 返回 `null` 表示"没有任何可用的地址"：既没存过，也没在构建时配默认值。
  /// 这是完全正常的状态（开源构建下就是这样），调用方应该让用户自己填。
  Future<Uri?> load() async {
    String? raw;
    try {
      raw = (await _prefs).getString(_key);
    } on Exception {
      // 存储层出问题不该挡住启动，用默认值继续。
      return _configuredDefault();
    }

    if (raw == null) {
      return _configuredDefault();
    }

    final EntryParseResult result = parseEntry(raw);
    return switch (result) {
      EntryParseOk(:final uri) => uri,
      // 存的东西坏了：不报错，安静地用默认值。
      EntryParseError() => _configuredDefault(),
    };
  }

  /// 构建时配的默认入口，没配就是 null。
  ///
  /// 注意这里要判断**空字符串**：`--dart-define` 不传时
  /// [kDefaultEntryUrl] 是 `''`，而 `Uri.parse('')` 会返回一个
  /// scheme/host 全空的 Uri —— 那个东西喂给 WebView 只会得到一片空白，
  /// 还不如明确地告诉调用方"没有默认值"。
  Uri? _configuredDefault() {
    if (kDefaultEntryUrl.trim().isEmpty) {
      return null;
    }
    final EntryParseResult result = parseEntry(kDefaultEntryUrl);
    return switch (result) {
      EntryParseOk(:final uri) => uri,
      EntryParseError() => null,
    };
  }

  /// 保存入口地址。
  ///
  /// 只存 [normalizeToOrigin] 规范化后的结果 —— 带 `?token=` 的 URL 到这里已经被剥干净了
  /// （雷区 5：令牌用完即废，记住它只会导致下次 401）。
  Future<void> save(Uri uri) async {
    await (await _prefs).setString(_key, normalizeToOrigin(uri).toString());
  }

  /// 忘掉存过的地址（"恢复默认"用）。下次 [load] 会回到 [kDefaultEntryUrl]。
  Future<void> clear() async {
    await (await _prefs).remove(_key);
  }
}
