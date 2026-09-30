/// 地址解析与校验。
///
/// 这个文件**故意不依赖 Flutter**：纯函数、纯 Dart，所以能被单元测试完整覆盖，
/// 也能在没有任何 WebView 的环境下跑。所有"用户到底想连哪儿"的判断都收敛在这里。
library;

import 'config.dart';

/// 把任意 URI 规范化成"入口 origin"：`scheme://host[:port]/`。
///
/// 三件事一起做，所以必须只用这一个函数，别各处自己 `Uri(...)` 拼：
/// - 丢掉 path / query / fragment（`?token=` 在这一步消失）
/// - 端口不存在时不补默认端口（`http://1.2.3.4/` 不该变成 `:80`）
/// - **保留根路径 `/`** —— 这样 `http://10.0.0.5/` 存进去再读出来还是原样，
///   而且 WebView 拿到的是一个明确的根地址而不是"没有路径"的怪东西
Uri normalizeToOrigin(Uri uri) {
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: '/',
  );
}

/// 地址解析的结果。用密封类而不是抛异常 —— 调用方必须显式处理失败分支，
/// 不会漏掉错误路径。
sealed class EntryParseResult {
  const EntryParseResult();
}

/// 解析成功。[uri] 已规范化（只保留 origin），[warning] 非 null 表示"能用但得提醒"。
class EntryParseOk extends EntryParseResult {
  const EntryParseOk(this.uri, {this.token, this.warning});

  /// 规范化后的入口地址，只含 scheme + host + port，**不含 path/query/fragment**。
  ///
  /// 这是唯一会被持久化的东西。令牌**不在**这里。
  final Uri uri;

  /// dsh web 的启动令牌（来自 `?token=`），没有就是 null。
  ///
  /// ⚠️ **绝不能持久化它**：令牌每次 dsh web 重启都会变，且只存在内存 +
  /// 服务端重启后就会失效。存下来只会在下次启动时得到一个过期的 401。
  /// 它的唯一用途是拼出 [launchUri] 走一次导航，换回 365 天的 Cookie。
  final String? token;

  /// 可选的提醒文案，例如端口不在常见区间内。为 null 表示一切正常。
  final String? warning;

  /// 这个入口是否命中已知白名单 host（影响证书放行与 UI 上的入口标签）。
  bool get isKnownHost => kKnownHosts.contains(uri.host);

  /// 真正应该交给 WebView 加载的地址。
  ///
  /// 带令牌时把 `?token=` 拼回去 —— 不拼的话 dsh 只会回
  /// "dsh web authentication required; reopen the URL printed by dsh web."，
  /// 因为那是**服务端自己的**鉴权层，跟前面那层 Basic 挑战是两码事。
  Uri get launchUri =>
      token == null ? uri : uri.replace(queryParameters: <String, String>{kTokenQueryKey: token!});
}

/// 解析失败。[reason] 是直接可以显示给用户的中文原因。
class EntryParseError extends EntryParseResult {
  const EntryParseError(this.reason);

  final String reason;
}

/// 判断一个字符串像不像主机名（可带端口）。
///
/// 只在"用户没写 scheme、我们要替他补一个"时使用。存在的理由是
/// `Uri.tryParse('https://' + 任意文字)` **几乎从不失败** —— 中文、空格、
/// 随便什么都会被百分号编码成 host，于是 `parseEntry('这不是地址')` 会
/// 返回一个看着合法的 `https://%E8%BF%99.../`。那是个坏 host，
/// 用户要到"连不上"时才发现，错误信息还完全对不上。
///
/// 所以补 scheme 之前先过这道闸：只接受
/// 字母/数字/连字符/点的域名（含 IPv4）或带方括号的 IPv6，后可跟 `:端口`。
bool _looksLikeHost(String value) {
  // 去掉可能存在的路径/查询部分，只看 authority。
  final String authority = value.split(RegExp(r'[/?#]')).first;
  if (authority.isEmpty) {
    return false;
  }

  final String hostPart = authority.startsWith('[')
      // IPv6：[::1]:7010 —— 取到右括号为止。
      ? (authority.contains(']')
            ? authority.substring(1, authority.indexOf(']'))
            : '')
      : authority.split(':').first;

  if (hostPart.isEmpty) {
    return false;
  }

  // 端口部分（如果写了）必须是纯数字。
  if (!authority.startsWith('[') && authority.contains(':')) {
    final String portPart = authority.substring(authority.indexOf(':') + 1);
    if (portPart.isNotEmpty && int.tryParse(portPart) == null) {
      return false;
    }
  }

  // 域名 / IPv4：字母数字与 - . ，且不能以 . 或 - 开头结尾。
  // 故意不接受中文和其它非 ASCII —— 入口是主机名/IP，不该有国际化域名。
  return RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.\-]*[A-Za-z0-9])?$').hasMatch(hostPart);
}

/// 把用户输入的原始字符串解析成一个入口地址。
///
/// 规则：
/// - 只接受 http/https；其它 scheme 一律拒绝
/// - host 不能为空，且**必须像个真正的主机名**（见 [_looksLikeHost]）
/// - 端口落在 [kFrpsPortMin]–[kFrpsPortMax] 之外时**只给警告，不拒绝**（服务端端口会变）
/// - 一律丢弃 path / query / fragment。**`?token=` 在这里就被扔掉**（雷区 5）：
///   令牌是一次性的，记住它只会导致下次打开时 401 的困惑
EntryParseResult parseEntry(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const EntryParseError('请输入地址');
  }

  // 用户往往只敲 "example.com:7010"，不带 scheme，所以这里替他补一个 https。
  // 但补之前必须先确认剩下的部分真的像个主机名，否则随便什么文字都会被
  // 当成合法 host（见 _looksLikeHost 的注释）。
  final bool hasScheme = trimmed.contains('://');
  if (!hasScheme && !_looksLikeHost(trimmed)) {
    return const EntryParseError('这看起来不是个地址，试试 example.com:7010 这种格式');
  }

  final String candidate = hasScheme ? trimmed : 'https://$trimmed';

  final Uri? parsed = Uri.tryParse(candidate);
  if (parsed == null) {
    return const EntryParseError('地址格式不对');
  }

  if (!kAllowedSchemes.contains(parsed.scheme)) {
    return EntryParseError('只支持 http / https，不支持 ${parsed.scheme}');
  }

  if (parsed.host.isEmpty) {
    return const EntryParseError('地址里没找到主机名');
  }

  // 规范化：只留 origin，并且**固定带上根路径 `/`**。
  // path/query/fragment 全丢。
  final Uri origin = normalizeToOrigin(parsed);

  // 启动令牌单独抽出来交给调用方用一次 —— 它**不进 origin**，
  // 所以不会被持久化（见 entry_store.dart）。见 [EntryParseOk.launchUri]。
  final String? token = parsed.queryParameters[kTokenQueryKey];

  // hasPort 为 false 时 port 在 Uri 里是默认值（80/443），此时不提醒。
  String? warning;
  if (parsed.hasPort) {
    final int port = parsed.port;
    if (port < kFrpsPortMin || port > kFrpsPortMax) {
      warning =
          '端口 $port 不在常见区间 $kFrpsPortMin–$kFrpsPortMax 内，'
          '可能连不上（服务端换端口时会这样，确认一下再连）';
    }
  }

  return EntryParseOk(
    origin,
    token: (token != null && token.isNotEmpty) ? token : null,
    warning: warning,
  );
}

/// 从扫码/粘贴得到的字符串里解析出入口 + 启动令牌。
///
/// 二维码内容形如 `https://example.com:7010/?token=<43位base64url>`。
/// 返回 null 表示这段文字不是有效地址（调用方应提示用户，而不是静默忽略）。
///
/// 注意令牌**不丢弃**了（早期版本丢弃，导致扫完码还是连不上 —— 见
/// [EntryParseOk.launchUri] 的说明）。但也**不持久化**，只在内存里活到第一次导航。
EntryParseOk? extractEntryFromScan(String scanned) {
  final String trimmed = scanned.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  // 整体必须能解析成 http/https URL。不做"从长文本里抠 URL"这种猜测 ——
  // 抠错了只会让用户更难理解为什么连不上。
  final Uri? parsed = Uri.tryParse(trimmed);
  if (parsed == null || !kAllowedSchemes.contains(parsed.scheme)) {
    return null;
  }
  if (parsed.host.isEmpty) {
    return null;
  }

  final EntryParseResult result = parseEntry(trimmed);
  return switch (result) {
    EntryParseOk() => result,
    EntryParseError() => null,
  };
}

/// 给 UI 用的入口标签：区分外网/内网/未知，纯展示用途。
///
/// 判定依据是 [kKnownHosts] 的顺序（外网在前、内网在后，见 config.dart），
/// 这样以后往白名单里加主机时，不用回来改这里的 if。
String describeEntry(Uri uri) {
  final int index = kKnownHosts.indexOf(uri.host);
  return switch (index) {
    0 => '外网',
    1 => '内网',
    _ => '自定义',
  };
}
