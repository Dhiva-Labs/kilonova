import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';

/// An icon in the system tray with a menu of two items, Open Kilonova and
/// Quit; clicking the icon opens the window too. No native library: on
/// Linux it speaks the StatusNotifierItem protocol over D-Bus, on Windows
/// the runner adds the icon (`windows/runner/tray_icon.cpp`).
abstract class Tray {
  /// The tray for this platform, or `null` where there is none.
  static Tray? forPlatform({
    required String title,
    required String openLabel,
    required String quitLabel,
  }) {
    if (Platform.isLinux) {
      return LinuxTray(
        title: title,
        openLabel: openLabel,
        quitLabel: quitLabel,
      );
    }
    if (Platform.isWindows) {
      return WindowsTray(
        title: title,
        openLabel: openLabel,
        quitLabel: quitLabel,
      );
    }
    return null;
  }

  /// Called when the owner clicks the icon or chooses Open Kilonova.
  void Function()? onOpen;

  /// Called when the owner chooses Quit.
  void Function()? onQuit;

  /// Whether the desktop shows tray icons at all.
  Future<bool> available();

  Future<void> show();

  Future<void> hide();
}

/// Windows: the icon lives in the runner, reached over `kilonova/tray`.
class WindowsTray extends Tray {
  WindowsTray({
    required this.title,
    required this.openLabel,
    required this.quitLabel,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'open':
          onOpen?.call();
        case 'quit':
          onQuit?.call();
      }
    });
  }

  static const _channel = MethodChannel('kilonova/tray');
  final String title;
  final String openLabel;
  final String quitLabel;

  @override
  Future<bool> available() async => true;

  @override
  Future<void> show() => _channel.invokeMethod<void>('show', {
    'tooltip': title,
    'open': openLabel,
    'quit': quitLabel,
  });

  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');
}

/// One size of the tray icon: ARGB32 pixels in network byte order, as
/// StatusNotifierItem's `IconPixmap` wants them.
class TrayPixmap {
  const TrayPixmap(this.width, this.height, this.argb);

  final int width;
  final int height;
  final Uint8List argb;

  /// Converts straight RGBA pixels (as `dart:ui` decodes them) to ARGB.
  factory TrayPixmap.fromRgba(int width, int height, Uint8List rgba) {
    final argb = Uint8List(rgba.length);
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      argb[i] = rgba[i + 3];
      argb[i + 1] = rgba[i];
      argb[i + 2] = rgba[i + 1];
      argb[i + 3] = rgba[i + 2];
    }
    return TrayPixmap(width, height, argb);
  }
}

const _itemInterface = 'org.kde.StatusNotifierItem';
const _menuInterface = 'com.canonical.dbusmenu';
const _watcherName = 'org.kde.StatusNotifierWatcher';
const _itemPath = '/StatusNotifierItem';
const _menuPath = '/MenuBar';

/// Menu item ids; 0 is the root.
const trayOpenId = 1;
const traySeparatorId = 2;
const trayQuitId = 3;

/// Linux: a StatusNotifierItem with a `com.canonical.dbusmenu` menu,
/// registered with the desktop's StatusNotifierWatcher (KDE, most others,
/// GNOME with the AppIndicator extension).
class LinuxTray extends Tray {
  LinuxTray({
    required this.title,
    required this.openLabel,
    required this.quitLabel,
    this.pixmaps = const [],
    DBusClient Function()? bus,
  }) : _bus = bus ?? DBusClient.session;

  final String title;
  final String openLabel;
  final String quitLabel;

  /// The icon, in one or more sizes; set before [show].
  List<TrayPixmap> pixmaps;

  final DBusClient Function() _bus;
  DBusClient? _client;
  TrayItemObject? _item;
  TrayMenuObject? _menu;
  static var _instances = 0;

  @override
  Future<bool> available() async {
    final client = _bus();
    try {
      if (!await client.nameHasOwner(_watcherName)) return false;
      final value =
          await DBusRemoteObject(
            client,
            name: _watcherName,
            path: DBusObjectPath('/StatusNotifierWatcher'),
          ).getProperty(
            _watcherName,
            'IsStatusNotifierHostRegistered',
            signature: DBusSignature('b'),
          );
      return value.asBoolean();
    } on Object {
      return false;
    } finally {
      await client.close();
    }
  }

  @override
  Future<void> show() async {
    if (_client != null) return;
    final client = _bus();
    final item = TrayItemObject(this);
    final menu = TrayMenuObject(this);
    await client.registerObject(item);
    await client.registerObject(menu);
    final name = 'org.kde.StatusNotifierItem-$pid-${++_instances}';
    await client.requestName(name);
    await DBusRemoteObject(
      client,
      name: _watcherName,
      path: DBusObjectPath('/StatusNotifierWatcher'),
    ).callMethod(_watcherName, 'RegisterStatusNotifierItem', [
      DBusString(name),
    ], replySignature: DBusSignature(''));
    _client = client;
    _item = item;
    _menu = menu;
  }

  @override
  Future<void> hide() async {
    final client = _client;
    _client = null;
    _item = null;
    _menu = null;
    // Closing the connection drops the name; the watcher then removes the
    // icon.
    await client?.close();
  }

  /// Whether the icon is registered; for tests.
  bool get shown => _item != null && _menu != null;
}

/// `org.kde.StatusNotifierItem` at `/StatusNotifierItem`.
class TrayItemObject extends DBusObject {
  TrayItemObject(this.tray) : super(DBusObjectPath(_itemPath));

  final LinuxTray tray;

  DBusValue _pixmaps() => DBusArray(DBusSignature('(iiay)'), [
    for (final p in tray.pixmaps)
      DBusStruct([
        DBusInt32(p.width),
        DBusInt32(p.height),
        DBusArray.byte(p.argb),
      ]),
  ]);

  Map<String, DBusValue> properties() => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': const DBusString('kilonova'),
    'Title': DBusString(tray.title),
    'Status': const DBusString('Active'),
    'IconName': const DBusString(''),
    'IconPixmap': _pixmaps(),
    'ToolTip': DBusStruct([
      const DBusString(''),
      DBusArray(DBusSignature('(iiay)'), const []),
      DBusString(tray.title),
      const DBusString(''),
    ]),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath(_menuPath),
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _itemInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Activate':
      case 'SecondaryActivate':
        tray.onOpen?.call();
        return DBusMethodSuccessResponse();
      case 'ContextMenu':
      case 'Scroll':
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == _itemInterface ? properties()[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _itemInterface ? properties() : {},
      );
}

/// `com.canonical.dbusmenu` at `/MenuBar`: Open Kilonova, a separator,
/// Quit. The menu never changes, so the revision stays 1.
class TrayMenuObject extends DBusObject {
  TrayMenuObject(this.tray) : super(DBusObjectPath(_menuPath));

  final LinuxTray tray;

  Map<String, DBusValue> itemProperties(int id) => switch (id) {
    0 => {'children-display': const DBusString('submenu')},
    trayOpenId => {'label': DBusString(tray.openLabel)},
    traySeparatorId => {'type': const DBusString('separator')},
    trayQuitId => {'label': DBusString(tray.quitLabel)},
    _ => const {},
  };

  DBusStruct _node(int id, {required bool children}) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(itemProperties(id)),
    DBusArray.variant([
      if (children)
        for (final child in const [trayOpenId, traySeparatorId, trayQuitId])
          _node(child, children: false),
    ]),
  ]);

  /// `GetLayout`'s answer for [parent]: the revision and the item with its
  /// children.
  List<DBusValue> layout(int parent) => [
    const DBusUint32(1),
    _node(parent, children: parent == 0),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _menuInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final args = methodCall.values;
    switch (methodCall.name) {
      case 'GetLayout':
        return DBusMethodSuccessResponse(layout(args[0].asInt32()));
      case 'GetGroupProperties':
        final ids = args[0].asInt32Array();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids)
              DBusStruct([
                DBusInt32(id),
                DBusDict.stringVariant(itemProperties(id)),
              ]),
          ]),
        ]);
      case 'GetProperty':
        final value = itemProperties(args[0].asInt32())[args[1].asString()];
        return value == null
            ? DBusMethodErrorResponse.invalidArgs()
            : DBusMethodSuccessResponse([DBusVariant(value)]);
      case 'Event':
        if (args[1].asString() == 'clicked') clicked(args[0].asInt32());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        for (final event in args[0].asArray()) {
          final fields = event.asStruct();
          if (fields[1].asString() == 'clicked') clicked(fields[0].asInt32());
        }
        return DBusMethodSuccessResponse([DBusArray.int32(const [])]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return DBusMethodSuccessResponse([
          DBusArray.int32(const []),
          DBusArray.int32(const []),
        ]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  /// A menu item was chosen.
  void clicked(int id) {
    switch (id) {
      case trayOpenId:
        tray.onOpen?.call();
      case trayQuitId:
        tray.onQuit?.call();
    }
  }

  Map<String, DBusValue> properties() => {
    'Version': const DBusUint32(3),
    'TextDirection': const DBusString('ltr'),
    'Status': const DBusString('normal'),
    'IconThemePath': DBusArray.string(const []),
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == _menuInterface ? properties()[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(
        interface == _menuInterface ? properties() : {},
      );
}
