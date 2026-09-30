import 'package:dsh_pocket/config.dart';
import 'package:dsh_pocket/entry_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只测 [parseEntry] / [extractEntryFromScan] / [describeEntry]。
///
/// 这三个是纯函数，也是全 App 唯一有真实逻辑分支的地方 —— 界面和 WebView 都得
/// 在真机上验，但"用户输入的地址到底被解析成了什么"必须在这里锁死。
void main() {
  group('parseEntry —— 合法输入', () {
    test('带端口的 https 原样通过', () {
      final result = parseEntry('https://198.51.100.10:7010/');
      expect(result, isA<EntryParseOk>());
      final ok = result as EntryParseOk;
      expect(ok.uri.host, '198.51.100.10');
      expect(ok.uri.port, 7010);
      expect(ok.uri.scheme, 'https');
      expect(ok.warning, isNull);
    });

    test('内网 http 通过', () {
      final result = parseEntry('http://10.0.0.5/');
      expect(result, isA<EntryParseOk>());
      expect((result as EntryParseOk).uri.toString(), 'http://10.0.0.5/');
    });

    test('不带 scheme 时默认补 https', () {
      final result = parseEntry('198.51.100.10:7010');
      expect(result, isA<EntryParseOk>());
      expect((result as EntryParseOk).uri.scheme, 'https');
      expect(result.uri.port, 7010);
    });

    test('首尾空格被忽略', () {
      expect(parseEntry('  https://198.51.100.10:7010/  '), isA<EntryParseOk>());
    });

    test('path / query / fragment 全部丢弃，只留 origin', () {
      final result = parseEntry('https://198.51.100.10:7010/some/path?a=1#frag');
      final ok = result as EntryParseOk;
      expect(ok.uri.path, '/');
      expect(ok.uri.query, isEmpty);
      expect(ok.uri.fragment, isEmpty);
      expect(ok.uri.toString(), 'https://198.51.100.10:7010/');
    });

    test('默认端口不被写出来', () {
      // http -> 不该变成 :80；这样存下来再读出来还是用户当初敲的样子。
      expect(
        (parseEntry('http://10.0.0.5') as EntryParseOk).uri.toString(),
        'http://10.0.0.5/',
      );
    });
  });

  group('normalizeToOrigin —— 幂等，存进去读出来不变', () {
    test('反复规范化结果稳定', () {
      final Uri once = normalizeToOrigin(
        Uri.parse('https://198.51.100.10:7010/a/b?token=x#y'),
      );
      expect(once.toString(), 'https://198.51.100.10:7010/');
      expect(normalizeToOrigin(once).toString(), once.toString());
    });

    test('无端口的主机保留根路径且不补端口', () {
      expect(
        normalizeToOrigin(Uri.parse('http://10.0.0.5/')).toString(),
        'http://10.0.0.5/',
      );
    });
  });

  group('parseEntry —— token 必须被剥掉（雷区 5）', () {
    test('带 ?token= 的扫码地址不会把 token 存进 origin Uri', () {
      final result = parseEntry(
        'https://198.51.100.10:7010/?token=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK',
      );
      final ok = result as EntryParseOk;
      // 令牌是一次性的，绝不能被"记住"（origin 是唯一会被持久化的东西）。
      expect(ok.uri.query, isEmpty);
      expect(ok.uri.toString(), 'https://198.51.100.10:7010/');
      expect(ok.uri.toString().contains('token'), isFalse);
      // 但它要能用于这一次导航，否则 dsh 会回
      // "dsh web authentication required; reopen the URL printed by dsh web."
      expect(ok.token, isNotNull);
      expect(ok.launchUri.query, contains('token='));
    });
  });

  group('parseEntry —— 非法输入返回错误而不是抛异常', () {
    test('空字符串', () {
      final result = parseEntry('');
      expect(result, isA<EntryParseError>());
      expect((result as EntryParseError).reason, '请输入地址');
    });

    test('纯空格', () {
      expect(parseEntry('   '), isA<EntryParseError>());
    });

    test('不支持的 scheme', () {
      final result = parseEntry('ftp://198.51.100.10');
      expect(result, isA<EntryParseError>());
      expect((result as EntryParseError).reason, contains('http'));
    });

    test('没有主机名', () {
      expect(parseEntry('https://'), isA<EntryParseError>());
    });

    test('随手打的文字不会被当成主机名', () {
      // 曾经的 bug：Uri.tryParse 会把中文百分号编码成 host，
      // 于是 "这不是地址" 变成了一个看着合法的 https://%E8%BF%99.../
      expect(parseEntry('这不是地址'), isA<EntryParseError>());
    });

    test('含空格/中文的纯文字拒绝', () {
      // 注意：单个英文单词（如 "garbage"）会被当成合法主机名 —— 这是有意的，
      // 因为内网主机完全可能叫 `nas` / `localhost` 这种短名字，
      // 单看字符串无法与"随手打的字"区分。真正的闸门是：含空格、含非 ASCII
      // （中文等）一律拒绝，那才是明显不像地址的输入。
      expect(parseEntry('hello world'), isA<EntryParseError>());
      expect(parseEntry('这不是地址'), isA<EntryParseError>());
      expect(parseEntry('a b'), isA<EntryParseError>());
    });

    test('端口写了非数字时拒绝', () {
      expect(parseEntry('198.51.100.10:abc'), isA<EntryParseError>());
    });
  });

  group('parseEntry —— 端口区间只警告不拒绝（雷区 6）', () {
    test('区间内无警告', () {
      for (final int port in <int>[kFrpsPortMin, 7010, kFrpsPortMax]) {
        final ok = parseEntry('https://198.51.100.10:$port') as EntryParseOk;
        expect(ok.warning, isNull, reason: '端口 $port 不该有警告');
      }
    });

    test('区间外给警告但仍然可用', () {
      final ok = parseEntry('https://198.51.100.10:8080') as EntryParseOk;
      // 关键：仍然是 Ok，不是 Error。服务端换端口时不能把用户锁死。
      expect(ok.warning, isNotNull);
      expect(ok.warning, contains('8080'));
      expect(ok.uri.port, 8080);
    });
  });

  group('isKnownHost —— 决定证书是否放行', () {
    test('白名单内的 host 全部命中', () {
      for (final String host in kKnownHosts) {
        final ok = parseEntry('https://$host:7010') as EntryParseOk;
        expect(ok.isKnownHost, isTrue, reason: '$host 应该在白名单里');
      }
    });

    test('白名单外不命中（这些一律拒绝放行自签证书）', () {
      final ok = parseEntry('https://evil.example.com:7010') as EntryParseOk;
      expect(ok.isKnownHost, isFalse);
    });
  });

  group('extractEntryFromScan —— 二维码导入', () {
    test('典型二维码 URL：origin 干净，但令牌被保留下来', () {
      final parsed = extractEntryFromScan(
        'https://198.51.100.10:7010/?token=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK',
      );

      expect(parsed, isNotNull);

      // origin 依然不带 token —— 这是要被持久化的那一份。
      expect(parsed!.uri.toString(), 'https://198.51.100.10:7010/');
      expect(parsed.uri.query, isEmpty);

      // 但令牌必须留着，否则 WebView 加载后会撞上
      // "dsh web authentication required; reopen the URL printed by dsh web."
      expect(parsed.token, 'AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK');
      expect(
        parsed.launchUri.toString(),
        'https://198.51.100.10:7010/?token=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK',
      );
    });

    test('不带 token 时 launchUri 就是 origin', () {
      final parsed = extractEntryFromScan('https://198.51.100.10:7010/');
      expect(parsed!.token, isNull);
      expect(parsed.launchUri.toString(), 'https://198.51.100.10:7010/');
    });

    test('非 URL 内容返回 null', () {
      expect(extractEntryFromScan('这不是一个地址'), isNull);
      expect(extractEntryFromScan(''), isNull);
      expect(extractEntryFromScan('ftp://198.51.100.10'), isNull);
    });

    test('内网地址也能扫', () {
      expect(
        extractEntryFromScan('http://10.0.0.5/')?.uri.host,
        '10.0.0.5',
      );
    });
  });

  group('入口地址与令牌分离', () {
    test('parseEntry 保留 token 但 origin 不含它', () {
      final ok =
          parseEntry('https://198.51.100.10:7010/?token=SECRET') as EntryParseOk;
      // 持久化的是 ok.uri —— 它绝不能带 token。
      expect(ok.uri.query, isEmpty);
      expect(ok.uri.toString(), 'https://198.51.100.10:7010/');
      // 导航用的是 ok.launchUri —— 它要有 token。
      expect(ok.launchUri.queryParameters['token'], 'SECRET');
    });

    test('空 token 视作没有 token', () {
      final ok = parseEntry('https://198.51.100.10:7010/?token=') as EntryParseOk;
      expect(ok.token, isNull);
      expect(ok.launchUri.toString(), 'https://198.51.100.10:7010/');
    });
  });

  group('describeEntry —— 入口标签', () {
    // 注意：地址和 host 白名单现在是**构建时注入**的（见 lib/config.dart），
    // 默认全空。所以这里不能断言"某个具体 IP 一定是外网" ——
    // 只能断言"标签与 kKnownHosts 的次序 / 默认值一致"。
    test('不在白名单里的一律是「自定义」', () {
      expect(describeEntry(Uri.parse('https://example.com')), '自定义');
      expect(describeEntry(Uri.parse('https://198.51.100.10')), '自定义');
    });

    test('白名单里的 host 按次序得到外网/内网', () {
      if (kKnownHosts.isEmpty) {
        // 默认构建（没传 --dart-define）就是这种情况：白名单空，
        // 任何 host 都是「自定义」。这本身就是要保证的安全默认值。
        return;
      }
      expect(describeEntry(Uri.parse('https://${kKnownHosts.first}')), '外网');
      if (kKnownHosts.length > 1) {
        expect(
          describeEntry(Uri.parse('https://${kKnownHosts[1]}')),
          '内网',
        );
      }
    });
  });

  group('默认配置 —— 没传 --dart-define 时的安全默认值', () {
    test('证书白名单默认为空（= 任何自签证书都不放行）', () {
      // 这条是刻意的：忘了配置的后果应该是"连不上"，而不是"悄悄信任了坏证书"。
      // 如果哪天有人给它加了个非空默认值，这个测试会失败，提醒他这是安全回归。
      expect(
        const String.fromEnvironment('DSH_KNOWN_HOSTS'),
        isEmpty,
        reason: 'kKnownHosts 的默认值必须为空',
      );
    });

    test('默认入口地址默认为空（不硬编码任何真实地址）', () {
      expect(kDefaultEntryUrl, isEmpty);
      expect(kInternalEntryUrl, isEmpty);
    });
  });
}
