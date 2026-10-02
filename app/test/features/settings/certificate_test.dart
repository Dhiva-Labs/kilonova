import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/rust.dart';

/// SHA-256 of test/fixtures/tls/cert.pem.
const _fingerprint =
    'EA:21:2E:47:C0:C4:BB:8A:0D:1A:2E:9D:5D:8A:30:73:4A:9D:67:E1:53:9D:5D:47:CD:D4:26:73:02:C2:F9:75';

/// A light wallet server over https with a self-signed certificate.
Future<HttpServer> _selfSignedLws() async {
  final context = SecurityContext()
    ..useCertificateChain('test/fixtures/tls/cert.pem')
    ..usePrivateKey('test/fixtures/tls/key.pem');
  final server = await HttpServer.bindSecure('127.0.0.1', 0, context);
  server.listen((request) async {
    await request.drain<void>();
    request.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'server_type': 'home',
          'blockchain_height': 9,
          'network_type': 'main',
        }),
      );
    await request.response.close();
  });
  return server;
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('a self-signed server is used only after its certificate is '
      'trusted', (tester) async {
    useDesktopWindow(tester);
    final server = (await tester.runAsync(_selfSignedLws))!;
    addTearDown(() => tester.runAsync(server.close));
    final url = 'https://localhost:${server.port}';

    await tester.pumpWidget(await testApp(tester));
    await openSettings(tester);
    await tester.tap(find.text('Light wallet servers'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), url);

    // Declining keeps it untrusted.
    await tester.tap(find.text('Save'));
    await pumpUntilFound(tester, find.text('Trust this certificate?'));
    expect(find.text(_fingerprint), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpUntilFound(
      tester,
      find.text("This server's certificate is not trusted."),
    );

    await tester.tap(find.text('Save'));
    await pumpUntilFound(tester, find.text('Trust this certificate?'));
    await tester.tap(find.text('Trust this certificate'));
    await pumpUntilFound(tester, find.text('home answering, at block 9'));
  });
}
