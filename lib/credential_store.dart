import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// HTTP Basic 凭据的持久化。
///
/// **为什么必须有这个**：HTTP Basic 挑战是**每个请求都查**的，
/// 而 Cookie 只能顶替服务端的会话层 —— 实测带上有效的会话 Cookie
/// Cookie 但不给 Basic 凭据，服务端照样回 401。所以"第二次打开免口令"
/// 只能靠两件事之一：
///
/// 1. Android WebView 内部的凭据库（`proceed()` 之后同 realm 自动复用）
/// 2. 我们**自己记住**凭据，下次挑战时自动应答
///
/// 第 1 条不可靠（插件没暴露任何相关 API，行为随系统/版本变），
/// 所以这里做第 2 条：记住上次输对的那组凭据，挑战来了直接送去，
/// 用户就不会再看到对话框。
///
/// **存哪儿**：系统密钥库（Android Keystore / macOS Keychain），
/// 不是 `shared_preferences`（那是明文 XML/plist，口令放进去等于裸奔）。
class CredentialStore {
  CredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// 按 **host** 分开存：内外网是两个入口，凭据通常也不一样。
  /// 用 host 而不是完整 origin，这样换端口不用重输。
  static String _userKey(String host) => 'basic_user_$host';
  static String _passKey(String host) => 'basic_pass_$host';

  final FlutterSecureStorage _storage;

  /// 读取某个 host 记住的凭据。没有就返回 null。
  ///
  /// **永远不抛异常**：密钥库偶尔会出问题（比如用户清了应用数据、
  /// 或 Android 上 keystore 被重置），那时只是读不到，不该让 App 崩。
  Future<BasicCredential?> read(String host) async {
    try {
      final String? user = await _storage.read(key: _userKey(host));
      final String? pass = await _storage.read(key: _passKey(host));
      if (user == null || pass == null) {
        return null;
      }
      return BasicCredential(user, pass);
    } on Exception {
      return null;
    }
  }

  /// 记下凭据（覆盖同 host 的旧值）。
  ///
  /// 失败也不抛 —— 存不进去的最坏后果只是下次再问一遍，
  /// 不该因此打断用户正在进行的登录。
  Future<void> write(String host, BasicCredential credential) async {
    try {
      await _storage.write(key: _userKey(host), value: credential.user);
      await _storage.write(key: _passKey(host), value: credential.password);
    } on Exception {
      // 忽略：见上面的说明。
    }
  }

  /// 忘掉某个 host 的凭据（"退出登录"时用）。
  Future<void> delete(String host) async {
    try {
      await _storage.delete(key: _userKey(host));
      await _storage.delete(key: _passKey(host));
    } on Exception {
      // 忽略。
    }
  }

  /// 忘掉所有 host 的凭据。
  ///
  /// 注意这里**不知道**有哪些 host 被存过（密钥库没有"按前缀列举"的
  /// 统一 API），所以调用方需要把已知的 host 传进来。
  Future<void> deleteAll(Iterable<String> hosts) async {
    for (final String host in hosts) {
      await delete(host);
    }
  }
}

/// 一组 HTTP Basic 凭据。只在内存里传递，落盘由 [CredentialStore] 负责。
class BasicCredential {
  const BasicCredential(this.user, this.password);

  final String user;
  final String password;
}
