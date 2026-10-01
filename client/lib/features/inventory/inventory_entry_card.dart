import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
import '../catalog/item_picture.dart';
import 'stock_labels.dart';

/// One item on the clinic's shelf: its name and status in words, how much is
/// there, how long it should last, where that estimate came from, and any
/// batch that expires soon. A red item carries the big **+** (requirement 12).
///
/// Built for older eyes: large text that wraps rather than truncates, a badge
/// that is a word and an icon as well as a colour, and nothing hidden behind
/// a gesture.
class InventoryEntryCard extends StatelessWidget {
  const InventoryEntryCard({required this.entry, this.onTap, super.key});

  final InventoryEntry entry;
  final VoidCallback? onTap;

  /// Days of cover a full bar stands for: a month, as in the design.
  static const fullBarDays = 30;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final source = sourceLabel(l10n, entry.estimate.source);
    final cover = entry.daysOfCover;
    final (tint, bar, ink) = switch (entry.status) {
      StockStatus.red => (colors.stockRedSoft, colors.stockRed, colors.stockRedInk),
      StockStatus.yellow => (colors.tileCream, colors.stockYellow, colors.stockYellowInk),
      StockStatus.green => (colors.tileMint, colors.stockGreen, colors.stockGreenInk),
      _ => (colors.pictureBackground, colors.border, colors.textMuted),
    };

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(16)),
                    alignment: Alignment.center,
                    child: ItemPicture.thumb(entry.item.imageUrl, size: 44),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.item.displayName, style: text.titleMedium),
                        Text(
                          quantityOf(l10n, entry.item, entry.qtyUnits),
                          style: TextStyle(fontSize: 15, color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Red asks for an order: the big + adds a box (requirement 12).
                  if (entry.status == StockStatus.red)
                    AddToCartButton(item: entry.item, size: 52)
                  // Unknown says nothing a clinic can act on: no badge at all.
                  else if (entry.status != StockStatus.unknown)
                    StockBadge(level: stockLevel(entry.status), label: stockLabel(l10n, entry)),
                ],
              ),
              // How long it lasts, only when the system knows (the user,
              // 2026-10-01: "not enough data" means nothing to clinic staff).
              // An empty shelf says «نفد» on its badge instead.
              if (entry.qtyUnits > 0 && cover != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: (cover / fullBarDays).clamp(0.04, 1.0),
                    minHeight: 9,
                    color: bar,
                    backgroundColor: colors.divider,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.daysOfCover(cover),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ink),
                ),
              ],
              if (entry.status == StockStatus.red) ...[
                const SizedBox(height: 6),
                StockBadge(level: stockLevel(entry.status), label: stockLabel(l10n, entry)),
              ],
              if (source != null) ...[
                const SizedBox(height: 4),
                Text(source, style: TextStyle(fontSize: 14, color: colors.textMuted)),
              ],
              for (final batch in entry.expiringBatches) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      batch.expired ? Icons.event_busy : Icons.schedule,
                      color: batch.expired ? colors.danger : colors.stockYellowInk,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        batch.expired
                            ? l10n.batchExpired(batch.batchNumber, formatCalendarDate(batch.expiryDate))
                            : l10n.batchExpiresOn(
                                batch.batchNumber,
                                formatCalendarDate(batch.expiryDate),
                              ),
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
