import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'core_config.dart';
import 'edit_page.dart';
import 'models.dart';
import 'qr_page.dart';
import 'tools_page.dart';
import 'widgets.dart';

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(BuildContext context, String title, String body, {String action = 'Delete'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return r == true;
}

Future<void> editProfile(BuildContext context, VpnController ctrl, Profile p) async {
  final r = await Navigator.push<Profile>(
    context,
    MaterialPageRoute(builder: (_) => EditPage(profile: p, all: ctrl.profiles, ctrl: ctrl)),
  );
  if (r != null) await ctrl.upsert(r);
}

/// "Add server" sheet: every profile type, paste import and subscriptions.
Future<void> addServerFlow(BuildContext context, VpnController ctrl) async {
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.88),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Add server', style: Theme.of(sheet).textTheme.titleLarge),
          ),
          for (final t in ProfileType.values)
            ListTile(
              leading: TypeAvatar(t),
              title: Text(typeLabel(t)),
              subtitle: Text(typeBlurb(t)),
              onTap: () => Navigator.pop(sheet, t),
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.content_paste),
            title: const Text('Paste link or config'),
            subtitle: const Text('vmess, vless, trojan, ss, hysteria2, ssh, socks5, wg-quick, .ovpn, Xray JSON'),
            onTap: () => Navigator.pop(sheet, 'import'),
          ),
          ListTile(
            leading: const Icon(Icons.rss_feed),
            title: const Text('Add subscription URL'),
            subtitle: const Text('Import and refresh a whole server list'),
            onTap: () => Navigator.pop(sheet, 'sub'),
          ),
        ]),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'import') return importFlow(context, ctrl);
  if (choice == 'sub') {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => SubscriptionsPage(ctrl: ctrl, addNow: true)));
    return;
  }
  final type = choice as ProfileType;
  await editProfile(context, ctrl, Profile(id: newId(), name: 'New ${typeShort(type)} server', type: type));
}

Future<void> importFlow(BuildContext context, VpnController ctrl) async {
  final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
  if (!context.mounted) return;
  final c = TextEditingController(text: clip);
  final text = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Import'),
      content: TextField(
        controller: c,
        minLines: 4,
        maxLines: 10,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'One or more links, a wg-quick or .ovpn config, Xray JSON, '
              'an exported profile or a full backup',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Import')),
      ],
    ),
  );
  if (text == null || !context.mounted) return;
  final t = text.trim();
  try {
    if (t.startsWith('{') && t.contains('"xray-vpn"')) {
      final n = await ctrl.importAll(t);
      if (context.mounted) toast(context, 'Backup restored ($n profiles)');
      return;
    }
    final lines = t.split(RegExp(r'[\r\n]+')).where((e) => e.contains('://')).toList();
    if (lines.length > 1 && !t.startsWith('{')) {
      var n = 0;
      for (final l in lines) {
        final p = importProfile(l, id: newId());
        if (p != null) {
          await ctrl.upsert(p);
          n++;
        }
      }
      if (context.mounted) toast(context, 'Imported $n servers');
      return;
    }
    final p = importProfile(t);
    if (p != null) {
      await ctrl.upsert(p);
      if (context.mounted) toast(context, 'Added "${p.name}"');
      return;
    }
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t) && context.mounted) {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => SubscriptionsPage(ctrl: ctrl, addNow: true, initialUrl: t)));
      return;
    }
    if (context.mounted) toast(context, 'Not recognised as a server, link or config');
  } catch (e) {
    if (context.mounted) toast(context, 'Import failed: $e');
  }
}

enum ProfileAction { edit, ping, sort, duplicate, copy, qr, delete }

Future<void> profileAction(
    BuildContext context, VpnController ctrl, Profile p, ProfileAction a) async {
  switch (a) {
    case ProfileAction.edit:
      return editProfile(context, ctrl, p);
    case ProfileAction.ping:
      return ctrl.ping(p);
    case ProfileAction.sort:
      await ctrl.sortGroupByLatency(p);
      if (context.mounted) toast(context, 'Group sorted by latency');
      return;
    case ProfileAction.duplicate:
      final j = p.toJson();
      await ctrl.upsert(Profile.fromJson({
        ...j,
        'id': newId(),
        'name': '${p.name} copy',
        'data': Map<String, dynamic>.from(p.data),
      }));
      return;
    case ProfileAction.copy:
      final link = shareLinkOf(p);
      final text = link ?? const JsonEncoder.withIndent('  ').convert(p.toJson()..remove('id'));
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) toast(context, link != null ? 'Link copied' : 'Configuration copied');
      return;
    case ProfileAction.qr:
      final link = shareLinkOf(p);
      if (link == null) {
        if (context.mounted) toast(context, 'QR codes are available for share-link servers only');
        return;
      }
      if (!context.mounted) return;
      await Navigator.push(
          context, MaterialPageRoute(builder: (_) => QrPage(title: p.name, data: link)));
      return;
    case ProfileAction.delete:
      if (await confirm(context, 'Delete "${p.name}"?', 'This cannot be undone.')) {
        await ctrl.remove(p.id);
      }
      return;
  }
}
