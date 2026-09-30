/// 上下游契约相关的常量集中在这里，别散落到各处。
///
/// **这个仓库里不硬编码任何真实的地址、域名或 IP。** 需要连接信息的人
/// 在构建时用 `--dart-define` 传进来（见下面几个常量的说明和 README）。
/// 这样做是因为本项目的默认入口是某台具体机器的公网地址，
/// 它不该出现在开源仓库里。
library;

// ---------------------------------------------------------------------------
// 构建时注入的配置
//
// 用法：
//   flutter build apk --release \
//     --dart-define=DSH_DEFAULT_URL=https://example.com:7010/ \
//     --dart-define=DSH_INTERNAL_URL=http://10.0.0.5/ \
//     --dart-define=DSH_KNOWN_HOSTS=example.com,10.0.0.5 \
//     --dart-define=DSH_BASIC_USER=myuser \
//     --dart-define=DSH_BASIC_HINT='myuser / XXXX-XXXX-XXXX-XXXX'
//
// 全部可选。不传的话 App 仍然能用 —— 只是第一次打开需要手动填地址，
// 且证书白名单为空（= 任何自签证书都不放行，这是安全的那一侧）。
// ---------------------------------------------------------------------------

/// 默认入口地址（通常是外网那个）。构建时注入。
///
/// 不传就是空字符串，首屏输入框留空，由用户自己填。
/// 注意端口**不是**固定的（见 [kFrpsPortMin] / [kFrpsPortMax]）。
const String kDefaultEntryUrl = String.fromEnvironment('DSH_DEFAULT_URL');

/// 备用入口（例如局域网内直连）。构建时注入，可选。
/// 不传就是空字符串。
const String kInternalEntryUrl = String.fromEnvironment('DSH_INTERNAL_URL');

/// HTTP Basic 的用户名。不传就是默认的 `dsh`。
///
/// 只用于在对话框里**预填用户名**，省得用户每次敲。口令本身永远不预填。
const String kBasicAuthUser = String.fromEnvironment(
  'DSH_BASIC_USER',
  defaultValue: 'dsh',
);

/// 凭据的格式提示。**这只是提示文案，不参与任何校验。**
///
/// 真实口令由 App 自己的对话框收集（见 `webview_screen.dart` 的
/// `_onHttpAuthRequest`）—— 注意**不能**指望 WebView 弹原生口令框：
/// `webview_flutter` 在原生层重写了 `onReceivedHttpAuthRequest`，
/// 没注册回调时会直接 cancel 掉请求。App 既不存储也不记录这个口令。
const String kBasicAuthHint = String.fromEnvironment(
  'DSH_BASIC_HINT',
  defaultValue: 'dsh / <你的口令>',
);

/// 证书放行的**唯一白名单**，逗号分隔。
///
/// 自建部署常用自签 CA 签发的证书（SAN 里可能直接写 IP，所以不能用域名通配匹配）。
/// WebView 遇到 SSL 错误时，只有 host 命中这个列表才允许 `proceed()`，
/// 其余一律 `cancel()` —— 这是本项目唯一的安全判断点，别放宽它。
///
/// **默认为空**：不配置就等于"任何自签证书都不放行"。
/// 这是刻意的安全默认值 —— 忘了配的后果是连不上，而不是悄悄信任了坏证书。
final List<String> kKnownHosts = _knownHostsFromEnv;

const String _knownHostsRaw = String.fromEnvironment('DSH_KNOWN_HOSTS');

/// 把 `DSH_KNOWN_HOSTS` 拆成列表，顺手去掉空白和空项。
///
/// 顶层 `final` 只算一次，开销可忽略。
final List<String> _knownHostsFromEnv = () {
  if (_knownHostsRaw.trim().isEmpty) {
    return const <String>[];
  }
  return _knownHostsRaw
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
}();

/// "常见端口"区间，仅用于**给个善意提醒**。
///
/// 服务端的入口端口可能被自动分配或调整，所以客户端不能假设它固定。
/// 因此超出这个区间时只提醒、**绝不拒绝** —— 否则服务端换端口时用户会被锁死。
const int kFrpsPortMin = 7000;
const int kFrpsPortMax = 7015;

/// 地址校验用的 scheme 白名单。
const List<String> kAllowedSchemes = <String>['http', 'https'];

/// dsh web 启动令牌的 query 参数名。
///
/// 带令牌的地址形如 `https://<入口>/?token=<一串令牌>`。
///
/// 是否要求令牌取决于服务端配置。要求时，不带令牌的请求会被拒绝并回一段
/// 提示（大意是"请重新打开服务端给出的 URL"）。
/// 带上它走一次导航，服务端通常会换成一个长期有效的 Cookie。
const String kTokenQueryKey = 'token';
