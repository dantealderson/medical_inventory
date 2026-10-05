import 'package:api_client/api_client.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../l10n/app_localizations.dart';
import '../orders/order_widgets.dart';

/// What an audit entry changed, as lines an admin can read: field names in
/// Arabic, statuses and money in words, record ids left out, unchanged
/// fields skipped. The log used to print the raw JSON, ids and all.
///
/// A field this does not know is still shown under its own name: the log
/// must never hide what was recorded.
List<String> auditChanges(AppLocalizations l10n, AuditEntry entry) {
  final before = _asMap(entry.before);
  final after = _asMap(entry.after);
  final lines = <String>[];

  // Order lines: what was approved of what was asked, per line.
  final requested = (before['lines'] as List?)?.cast<Map>() ?? const [];
  final approved = (after['lines'] as List?)?.cast<Map>() ?? const [];
  if (approved.isNotEmpty) {
    final asked = {for (final l in requested) l['orderLineId']: l['qtyBoxesRequested']};
    final parts = [
      for (final l in approved)
        '${l['qtyBoxesApproved']} ${l10n.auditOf} ${asked[l['orderLineId']] ?? '?'} ${l10n.boxesShort}',
    ];
    lines.add('${l10n.approvedQty}: ${parts.join('، ')}');
  }

  for (final key in {...before.keys, ...after.keys}) {
    if (key == 'lines' || _hidden.contains(key)) continue;
    final had = before.containsKey(key);
    final has = after.containsKey(key);
    final label = _label(l10n, key);
    String show(Object? v) => _value(l10n, key, v);
    if (had && has) {
      if ('${before[key]}' == '${after[key]}') continue;
      lines.add(l10n.auditFromTo(label, show(before[key]), show(after[key])));
    } else {
      lines.add('$label: ${show(has ? after[key] : before[key])}');
    }
  }

  // The server's notes are written for developers, in English; the action's
  // own label already says it. An Arabic note is the admin's, and stays.
  final note = entry.note;
  if (note != null && RegExp(r'[؀-ۿ]').hasMatch(note)) lines.add(note);
  return lines;
}

/// Record ids say nothing to a person.
const _hidden = {'id', 'itemId', 'orderLineId', 'parentId', 'clientId', 'batchId', 'categoryId'};

Map<String, dynamic> _asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : const {};

String _label(AppLocalizations l10n, String key) => switch (key) {
  'stock.redDaysOfCover' => l10n.settingRedDays,
  'stock.yellowDaysOfCover' => l10n.settingYellowDays,
  'estimation.purchaseWindowDays' => l10n.settingPurchaseWindow,
  'estimation.minPurchaseDays' => l10n.settingMinPurchase,
  'estimation.minMeasureDays' => l10n.settingMinMeasure,
  'estimation.measurePairWindowDays' => l10n.settingMeasureWindow,
  'estimation.maxCatchUpDays' => l10n.settingMaxCatchUp,
  'alerts.repeatAfterDays' => l10n.settingRepeatAlerts,
  'expiry.warnDaysAhead' => l10n.settingWarnAhead,
  'expiry.minShelfLifeOnDeliveryDays' => l10n.settingMinShelfLife,
  'hotDeals.rotationSeconds' => l10n.settingRotation,
  'hotDeals.frequentWindowDays' => l10n.settingFrequentWindow,
  'hotDeals.newItemDays' => l10n.settingNewItemDays,
  'hotDeals.maxEntries' => l10n.settingMaxEntries,
  'business.timezone' => l10n.timezoneLabel,
  'status' => l10n.status,
  'isActive' => l10n.statusActive,
  'nameAr' => l10n.nameArLabel,
  'nameEn' => l10n.nameEnLabel,
  'pricePerBox' => l10n.pricePerBox,
  'totalAmount' => l10n.orderTotal,
  'batchNumber' => l10n.batchNumber,
  'expiryDate' => l10n.expiryDate,
  'qtyUnitsReceived' => l10n.auditQtyReceived,
  'reason' => l10n.cancelReason,
  'disposition' => l10n.dispositionLabel,
  'from' => l10n.auditCancelledFrom,
  'releasedUnits' => l10n.auditReleasedUnits,
  'level' => l10n.auditLevel,
  'imageUrl' => l10n.auditPicture,
  _ => key,
};

String _value(AppLocalizations l10n, String key, Object? v) {
  if (v == null) return l10n.nothingToShow;
  if (v is bool) return v ? l10n.yes : l10n.no;
  return switch (key) {
    'pricePerBox' || 'totalAmount' => formatIqd('$v'),
    'status' => switch ('$v') {
      'PENDING' => l10n.statusPending,
      'ACTIVE' => l10n.statusActive,
      'SUSPENDED' => l10n.statusSuspended,
      'REJECTED' => l10n.statusRejected,
      _ => '$v',
    },
    'from' => orderStatusLabel(l10n, OrderStatus.fromWire('$v')),
    'disposition' => dispositionText(l10n, CancelDisposition.fromWire('$v')),
    'imageUrl' => l10n.auditPictureSet,
    _ => '$v',
  };
}
