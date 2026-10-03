import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/platform/tray.dart';

DBusMethodCall _call(String interface, String name, [List<DBusValue>? args]) =>
    DBusMethodCall(
      sender: ':1.1',
      interface: interface,
      name: name,
      values: args ?? const [],
    );

DBusMethodCall _event(int id, String kind) =>
    _call('com.canonical.dbusmenu', 'Event', [
      DBusInt32(id),
      DBusString(kind),
      const DBusVariant(DBusInt32(0)),
      const DBusUint32(0),
    ]);

void main() {
  late LinuxTray tray;
  late List<String> events;

  setUp(() {
    events = [];
    tray =
        LinuxTray(
            title: 'Kilonova',
            openLabel: 'Open Kilonova',
            quitLabel: 'Quit',
            pixmaps: [
              TrayPixmap.fromRgba(1, 1, Uint8List.fromList([1, 2, 3, 4])),
            ],
          )
          ..onOpen = (() => events.add('open'))
          ..onQuit = (() => events.add('quit'));
  });

  test('icon pixels are converted to ARGB', () {
    expect(tray.pixmaps.single.argb, [4, 1, 2, 3]);
  });

  test('the item names the app, its icon and its menu', () async {
    final item = TrayItemObject(tray);
    final all =
        await item.getAllProperties('org.kde.StatusNotifierItem')
            as DBusMethodSuccessResponse;
    final props = all.values.single.asStringVariantDict();
    expect(props['Id']!.asString(), 'kilonova');
    expect(props['Title']!.asString(), 'Kilonova');
    expect(props['Status']!.asString(), 'Active');
    expect(props['Menu'], DBusObjectPath('/MenuBar'));
    expect(props['IconPixmap']!.signature, DBusSignature('a(iiay)'));
    final pixmap = props['IconPixmap']!.asArray().single.asStruct();
    expect(pixmap[0].asInt32(), 1);
    expect(pixmap[2].asByteArray(), [4, 1, 2, 3]);
  });

  test('clicking the icon opens the window', () async {
    final item = TrayItemObject(tray);
    final reply = await item.handleMethodCall(
      _call('org.kde.StatusNotifierItem', 'Activate', [
        const DBusInt32(0),
        const DBusInt32(0),
      ]),
    );
    expect(reply, isA<DBusMethodSuccessResponse>());
    expect(events, ['open']);
  });

  test('the menu has Open Kilonova, a separator and Quit', () async {
    final menu = TrayMenuObject(tray);
    final reply =
        await menu.handleMethodCall(
              _call('com.canonical.dbusmenu', 'GetLayout', [
                const DBusInt32(0),
                const DBusInt32(-1),
                DBusArray.string(const []),
              ]),
            )
            as DBusMethodSuccessResponse;
    expect(reply.signature, DBusSignature('u(ia{sv}av)'));
    final root = reply.values[1].asStruct();
    expect(root[0].asInt32(), 0);
    final children = [
      for (final child in root[2].asArray()) child.asVariant().asStruct(),
    ];
    expect([for (final c in children) c[0].asInt32()], [1, 2, 3]);
    final labels = [
      for (final c in children)
        c[1].asStringVariantDict()['label']?.asString() ??
            c[1].asStringVariantDict()['type']!.asString(),
    ];
    expect(labels, ['Open Kilonova', 'separator', 'Quit']);
  });

  test('menu clicks open the window or quit', () async {
    final menu = TrayMenuObject(tray);
    await menu.handleMethodCall(_event(trayOpenId, 'clicked'));
    await menu.handleMethodCall(_event(traySeparatorId, 'clicked'));
    await menu.handleMethodCall(_event(trayQuitId, 'hovered'));
    expect(events, ['open']);
    await menu.handleMethodCall(
      _call('com.canonical.dbusmenu', 'EventGroup', [
        DBusArray(DBusSignature('(isvu)'), [
          DBusStruct(_event(trayQuitId, 'clicked').values),
        ]),
      ]),
    );
    expect(events, ['open', 'quit']);
  });

  test('without a tray host the tray is not available', () async {
    final noHost = LinuxTray(
      title: 'Kilonova',
      openLabel: 'Open Kilonova',
      quitLabel: 'Quit',
      bus: () => DBusClient(DBusAddress.unix(path: '/nonexistent/bus')),
    );
    expect(await noHost.available(), isFalse);
  });
}
