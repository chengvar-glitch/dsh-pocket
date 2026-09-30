import 'package:dsh_pocket/credential_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [CredentialStore] 的测试。
///
/// 用 `FlutterSecureStorage` 的 MethodChannel mock 来驱动 ——
/// 单元测试里没有真的 Keystore/Keychain，直接跑会抛 MissingPluginException。
/// 这里既验证"正常路径"，也验证"密钥库坏了也要能优雅降级"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  /// 一个极简的内存版密钥库，记录调用以便断言。
  late Map<String, String> backend;
  late List<String> deletedKeys;

  setUp(() {
    backend = <String, String>{};
    deletedKeys = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          final Map<Object?, Object?> args =
              (call.arguments as Map<Object?, Object?>?) ??
              <Object?, Object?>{};
          final String? key = args['key'] as String?;

          switch (call.method) {
            case 'read':
              return backend[key];
            case 'write':
              backend[key!] = args['value'] as String;
              return null;
            case 'delete':
              deletedKeys.add(key!);
              backend.remove(key);
              return null;
            case 'readAll':
              return Map<String, String>.from(backend);
            case 'deleteAll':
              backend.clear();
              return null;
            case 'containsKey':
              return backend.containsKey(key);
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('没存过时读到 null', () async {
    expect(await CredentialStore().read('dsh.example.com'), isNull);
  });

  test('写进去能读回来', () async {
    final store = CredentialStore();
    await store.write('dsh.example.com', const BasicCredential('alice', 'pw1'));

    final BasicCredential? got = await store.read('dsh.example.com');
    expect(got, isNotNull);
    expect(got!.user, 'alice');
    expect(got.password, 'pw1');
  });

  test('凭据按 host 分开存，互不串味', () async {
    final store = CredentialStore();
    await store.write('a.example.com', const BasicCredential('ua', 'pa'));
    await store.write('b.example.com', const BasicCredential('ub', 'pb'));

    expect((await store.read('a.example.com'))!.user, 'ua');
    expect((await store.read('b.example.com'))!.user, 'ub');
    // 没存过的第三个 host 仍然是 null，不会串到别人的凭据。
    expect(await store.read('c.example.com'), isNull);
  });

  test('同一个 host 再写一次会覆盖（改口令的场景）', () async {
    final store = CredentialStore();
    await store.write('dsh.example.com', const BasicCredential('u', 'old'));
    await store.write('dsh.example.com', const BasicCredential('u', 'new'));

    expect((await store.read('dsh.example.com'))!.password, 'new');
  });

  test('delete 只清指定的 host', () async {
    final store = CredentialStore();
    await store.write('a.example.com', const BasicCredential('ua', 'pa'));
    await store.write('b.example.com', const BasicCredential('ub', 'pb'));

    await store.delete('a.example.com');

    expect(await store.read('a.example.com'), isNull);
    expect((await store.read('b.example.com'))!.user, 'ub');
    // 用户名和口令两个 key 都要被删掉，不能只删一个。
    expect(deletedKeys.where((String k) => k.contains('a.example.com')).length, 2);
  });

  test('只写了一半（用户名在、口令缺）时当作没存过', () async {
    // 模拟"写用户名成功、写口令失败"这种半截状态 ——
    // 不能拿半组凭据去应答挑战，那只会白挨一次 401。
    backend['basic_user_dsh.example.com'] = 'alice';

    expect(await CredentialStore().read('dsh.example.com'), isNull);
  });

  test('密钥库抛异常时读返回 null、写不抛出', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          throw PlatformException(code: 'boom', message: 'keystore broken');
        });

    final store = CredentialStore();
    // 读：优雅降级成"没存过"，而不是把启动流程炸掉。
    expect(await store.read('dsh.example.com'), isNull);
    // 写：吞掉异常 —— 最坏后果只是下次再问一遍，不该打断用户。
    await expectLater(
      store.write('dsh.example.com', const BasicCredential('u', 'p')),
      completes,
    );
  });
}
